import Foundation
import Observation
import XCTest
@testable import ToneHop

/// Injected HAL callbacks exercise the production AudioStore entry point. These
/// tests never start discovery, write a system output, or touch real listeners.
@MainActor
final class AudioNotificationStressTests: XCTestCase {
    func testFiftyThousandNotificationsHaveOneDeliveryWhileHALReadIsSuspended() async throws {
        let rig = NotificationStressRig()
        defer { rig.cleanUp() }
        try await rig.start()
        await rig.hardware.replaceCurrent(uid: "latest")

        let started = ContinuousClock.now
        rig.relay.emit(count: 50_000)
        let pulse = Task.detached { await rig.metrics.probeMainActor() }
        // This entire burst is produced in one MainActor turn, before delivery
        // can start. There must be exactly one queued invalidation for it.
        try await rig.routes.waitForDeliveries(1)
        await pulse.value
        let held = await rig.hardware.state()
        XCTAssertEqual(held.reads, 1, "The refresh pump must coalesce while its HAL read is in flight.")
        XCTAssertEqual(held.maximumConcurrentReads, 1)
        XCTAssertEqual(rig.routes.runtimeEvents, 1)

        await rig.hardware.finishSlowReads()
        try await rig.waitForCurrent("hal:latest")
        try await rig.store.shutdown()
        let finished = await rig.hardware.state()
        XCTAssertEqual(finished.reads, 2, "One follow-up read must retain the events received during the old read.")
        XCTAssertEqual(finished.writes, 0)
        XCTAssertEqual(finished.stops, 1)
        XCTAssertEqual(rig.routes.shutdowns, 1)
        record(rig, name: "single-burst-bounded", elapsed: started.duration(to: .now), hardware: finished)
    }

    func testTenSecondBackgroundNotificationStormWithControlledSlowReads() async throws {
        let rig = NotificationStressRig()
        defer { rig.cleanUp() }
        try await rig.start()
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(10))
        let relay = rig.relay
        let metrics = rig.metrics
        let hardware = rig.hardware

        // Four background producers remain active for at least ten seconds.
        // Each batch records one independent MainActor round trip. Its latency
        // is diagnostic data, never a machine-dependent pass/fail threshold.
        let producers = Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        while ContinuousClock.now < deadline {
                            relay.emit(count: 256)
                            await metrics.probeMainActor()
                        }
                    }
                }
                await group.waitForAll()
            }
        }
        let slowReader = Task.detached {
            while ContinuousClock.now < deadline {
                // This is the test's simulated slow-reader cadence, not a
                // correctness deadline. Only explicit release completes a read.
                try? await Task.sleep(for: .milliseconds(50))
                await hardware.releaseOneSlowRead()
            }
        }
        await producers.value
        await slowReader.value
        let held = await hardware.state()
        XCTAssertGreaterThan(held.reads, 1, "The sustained run must span several controlled HAL reads.")
        XCTAssertEqual(held.maximumConcurrentReads, 1)
        XCTAssertGreaterThan(metrics.sampleCount, 0)

        await hardware.replaceCurrent(uid: "final")
        let finalDelivery = rig.routes.runtimeEvents + 1
        relay.emit(count: 1)
        try await rig.routes.waitForDeliveries(finalDelivery)
        await hardware.finishSlowReads()
        try await rig.waitForCurrent("hal:final")
        try await rig.store.shutdown()
        let finished = await hardware.state()
        XCTAssertGreaterThan(rig.routes.runtimeEvents, 0)
        XCTAssertLessThanOrEqual(rig.routes.runtimeEvents, relay.emissions,
                                "An invalidation can merge events but must never multiply them.")
        XCTAssertEqual(finished.maximumConcurrentReads, 1)
        XCTAssertEqual(finished.writes, 0, "Notifications must never replay an output selection.")
        XCTAssertEqual(finished.stops, 1)
        XCTAssertEqual(rig.routes.shutdowns, 1)
        record(rig, name: "ten-second-background-bounded", elapsed: started.duration(to: .now), hardware: finished)
    }

    func testShutdownDuringNotificationStormWaitsForTheRealHALRead() async throws {
        let rig = NotificationStressRig()
        defer { rig.cleanUp() }
        try await rig.start()
        rig.relay.emit(count: 1_000)
        try await rig.routes.waitForDeliveries(1)
        let deliveredBeforeClose = rig.routes.runtimeEvents
        let staleCallback = try XCTUnwrap(rig.relay.registeredCallback)
        let started = ContinuousClock.now

        // No suspension from burst through stop: queued MainActor callbacks
        // cannot run before AudioStore has synchronously closed its lifecycle.
        rig.relay.emit(count: 50_000)
        rig.store.stop()
        XCTAssertEqual(rig.routes.shutdownBegins, 1)
        XCTAssertEqual(rig.routes.shutdowns, 0, "Resource release must await the still-suspended HAL read.")
        let shutdown = Task { try await rig.store.shutdown() }
        for _ in 0..<1_000 { staleCallback() }
        let pulse = Task.detached { await rig.metrics.probeMainActor() }
        await pulse.value
        let held = await rig.hardware.state()
        XCTAssertEqual(held.activeReads, 1)
        XCTAssertEqual(held.stops, 0)
        XCTAssertEqual(rig.routes.shutdowns, 0)
        XCTAssertEqual(rig.routes.runtimeEvents, deliveredBeforeClose, "Queued and late callbacks must not enter runtime coordination after close.")

        await rig.hardware.replaceCurrent(uid: "late-result")
        await rig.hardware.finishSlowReads()
        try await shutdown.value
        try await rig.store.shutdown()
        let finished = await rig.hardware.state()
        XCTAssertEqual(finished.reads, 1, "Shutdown must discard a queued refresh follow-up.")
        XCTAssertEqual(finished.maximumConcurrentReads, 1)
        XCTAssertEqual(finished.writes, 0)
        XCTAssertEqual(finished.stops, 1)
        XCTAssertEqual(rig.routes.shutdowns, 1)
        XCTAssertTrue(rig.store.devices.isEmpty, "The result of the cancelled in-flight read must not publish after shutdown.")
        record(rig, name: "storm-overlapping-shutdown", elapsed: started.duration(to: .now), hardware: finished,
               extra: ["lateCallbacksOutsideRelay": 1_000, "runtimeEventsBeforeClose": deliveredBeforeClose])
    }

    func testNotificationsReceivedDuringDeliveryScheduleOneFollowUp() async throws {
        let rig = NotificationStressRig()
        defer { rig.cleanUp() }
        try await rig.start()
        rig.routes.onRuntimeEvent = { [relay = rig.relay] count in
            // Re-enter through the actual registered HAL callback while the
            // first synchronous MainActor handler is still executing.
            if count == 1 { relay.emit(count: 50_000) }
        }

        rig.relay.emit(count: 50_000)
        try await rig.routes.waitForDeliveries(2)
        let held = await rig.hardware.state()
        XCTAssertEqual(rig.routes.runtimeEvents, 2,
                       "The first burst and the burst during its delivery must each admit one handler.")
        XCTAssertEqual(held.reads, 1)
        XCTAssertEqual(held.maximumConcurrentReads, 1)
        await rig.hardware.finishSlowReads()
        try await rig.waitForCurrent("hal:initial")
        try await rig.store.shutdown()
        let finished = await rig.hardware.state()
        XCTAssertEqual(finished.reads, 2)
        XCTAssertEqual(finished.writes, 0)
    }

    func testClosingBeforeQueuedDeliveryRejectsAllPendingAndLaterNotifications() async throws {
        let rig = NotificationStressRig()
        defer { rig.cleanUp() }
        try await rig.start()

        rig.relay.emit(count: 50_000)
        rig.store.stop()
        rig.relay.emit(count: 50_000)
        await rig.metrics.probeMainActor()
        XCTAssertEqual(rig.routes.runtimeEvents, 0)
        XCTAssertEqual(rig.routes.shutdownBegins, 1)
        XCTAssertEqual(rig.routes.shutdowns, 0)

        await rig.hardware.finishSlowReads()
        try await rig.store.shutdown()
        let finished = await rig.hardware.state()
        XCTAssertEqual(rig.routes.runtimeEvents, 0)
        XCTAssertEqual(finished.reads, 1)
        XCTAssertEqual(finished.stops, 1)
        XCTAssertTrue(rig.store.devices.isEmpty)
    }

    func testCancellingOwnedStreamQuitKeepsHALNotificationDeliveryOpen() async throws {
        let rig = NotificationStressRig()
        defer { rig.cleanUp() }
        try await rig.start()
        let owned = OwnedRouteExitEvidence(receiverID: "injected-receiver", streamUID: "owned-stream",
                                          name: "Injected receiver")
        rig.routes.ownedEvidence = owned

        let plan = try await rig.store.prepareToQuit()
        XCTAssertEqual(plan.ownedStream, owned)
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertTrue(rig.store.isPreparingToQuit)
        XCTAssertEqual(rig.routes.exitInspections, 1)
        XCTAssertEqual(rig.routes.shutdownBegins, 0)
        rig.relay.emit(count: 50_000)
        try await rig.routes.waitForDeliveries(1)
        let awaitingConfirmation = await rig.hardware.state()
        XCTAssertEqual(awaitingConfirmation.reads, 1)
        XCTAssertEqual(awaitingConfirmation.activeReads, 1)
        XCTAssertEqual(awaitingConfirmation.writes, 0)
        XCTAssertEqual(rig.routes.shutdownBegins, 0,
                       "Preflight and the confirmation state must not close notification admission.")

        rig.store.cancelQuit()
        XCTAssertFalse(rig.store.isPreparingToQuit)
        await rig.hardware.replaceCurrent(uid: "after-cancel")
        rig.relay.emit(count: 50_000)
        try await rig.routes.waitForDeliveries(2)
        await rig.hardware.finishSlowReads()
        try await rig.waitForCurrent("hal:after-cancel")
        let afterCancel = await rig.hardware.state()
        XCTAssertEqual(afterCancel.reads, 2)
        XCTAssertEqual(afterCancel.maximumConcurrentReads, 1)
        XCTAssertEqual(rig.routes.shutdownBegins, 0)

        // Cancel's own refresh has now finished. This different identity must
        // be discovered solely through another actual registered HAL callback.
        await rig.hardware.replaceCurrent(uid: "notification-after-cancel")
        rig.relay.emit(count: 50_000)
        try await rig.routes.waitForDeliveries(3)
        try await rig.waitForCurrent("hal:notification-after-cancel")
        XCTAssertEqual(rig.routes.ownedEvidence, owned)
        try await rig.store.shutdown()
        let finished = await rig.hardware.state()
        XCTAssertEqual(rig.routes.runtimeEvents, 3)
        XCTAssertEqual(rig.routes.shutdownBegins, 1)
        XCTAssertEqual(rig.routes.shutdowns, 1)
        XCTAssertEqual(finished.reads, 3)
        XCTAssertEqual(finished.writes, 0)
        XCTAssertEqual(finished.stops, 1)
    }

    private func record(_ rig: NotificationStressRig, name: String, elapsed: Duration,
                        hardware: NotificationStressHardware.State, extra: [String: Any] = [:]) {
        var report: [String: Any] = [
            "scenario": name,
            "elapsedSeconds": stressSeconds(elapsed),
            "notifications": rig.relay.emissions,
            "runtimeEntryDeliveries": rig.routes.runtimeEvents,
            "refreshReads": hardware.reads,
            "maximumConcurrentReads": hardware.maximumConcurrentReads,
            "systemWrites": hardware.writes,
            "hardwareStops": hardware.stops,
            "routeShutdowns": rig.routes.shutdowns,
            "mainActorProbe": rig.metrics.report(),
            "scope": "hosted XCTest with injected HAL callbacks and controlled read continuations; no real audio",
        ]
        report.merge(extra) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        let attachment = XCTAttachment(string: json)
        attachment.name = "audio-notification-stress-\(name).json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("AUDIO_NOTIFICATION_STRESS \(json)")
    }
}

@MainActor
private final class NotificationStressRig {
    let relay = NotificationStressRelay()
    let metrics = NotificationStressMetrics()
    let routes = NotificationStressRoutes()
    let hardware: NotificationStressHardware
    let store: AudioStore
    private let observing = XCTestExpectation(description: "injected HAL listener registered")
    private let firstRead = XCTestExpectation(description: "initial HAL read suspended")

    init() {
        let observing = observing
        let firstRead = firstRead
        hardware = NotificationStressHardware(relay: relay, onObserve: { observing.fulfill() },
                                              onFirstRead: { firstRead.fulfill() })
        store = AudioStore(hardware: hardware, routes: routes, pollingInterval: .seconds(3_600))
    }

    func start() async throws {
        store.start()
        try await stressWait([observing, firstRead])
    }

    func waitForCurrent(_ id: String) async throws {
        let expected = XCTestExpectation(description: "final hardware identity \(id) publishes")
        let observation = NotificationStressObservation(expected: expected) { [store] in
            store.currentDeviceID == id && !store.isRefreshing
        }
        observation.start()
        defer { observation.cancel() }
        try await stressWait([expected])
    }

    func cleanUp() {
        store.stop()
        let hardware = hardware
        Task { await hardware.finishSlowReads() }
    }
}

/// The relay deliberately keeps a copy of the registered callback after stop,
/// so shutdown can be tested against callbacks HAL had already captured.
private final class NotificationStressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private var count = 0

    func register(_ callback: @escaping @Sendable () -> Void) {
        lock.withLock { self.callback = callback }
    }

    var registeredCallback: (@Sendable () -> Void)? { lock.withLock { callback } }
    var emissions: Int { lock.withLock { count } }

    func emit(count: Int) {
        let callback = lock.withLock {
            self.count += count
            return self.callback
        }
        for _ in 0..<count { callback?() }
    }
}

private actor NotificationStressHardware: AudioHardwareProviding {
    struct State: Sendable {
        var reads = 0
        var activeReads = 0
        var maximumConcurrentReads = 0
        var writes = 0
        var stops = 0
    }

    private let relay: NotificationStressRelay
    private let onObserve: @Sendable () -> Void
    private let onFirstRead: @Sendable () -> Void
    private nonisolated let closing = AudioShutdownSignal()
    private var recorded = State()
    private var currentUID = "initial"
    private var holdReads = true
    private var pending: [CheckedContinuation<Void, Never>] = []

    init(relay: NotificationStressRelay, onObserve: @escaping @Sendable () -> Void,
         onFirstRead: @escaping @Sendable () -> Void) {
        self.relay = relay
        self.onObserve = onObserve
        self.onFirstRead = onFirstRead
    }

    func snapshot() async throws -> CoreAudioSnapshot {
        recorded.reads += 1
        recorded.activeReads += 1
        recorded.maximumConcurrentReads = max(recorded.maximumConcurrentReads, recorded.activeReads)
        let uid = currentUID
        if holdReads {
            await withCheckedContinuation { continuation in
                pending.append(continuation)
                if recorded.reads == 1 { onFirstRead() }
            }
        }
        recorded.activeReads -= 1
        // Deliberately return the identity captured before suspension, and do
        // not turn Task.cancel into a fictitious remote read completion.
        let device = AudioDevice(id: "hal:\(uid)", name: "Injected \(uid)", transport: .speaker,
                                 backend: .coreAudio(uid: uid))
        return CoreAudioSnapshot(devices: [device], currentDeviceID: device.id,
                                 systemSoundDeviceID: device.id, warnings: [])
    }

    func select(uid: String) { recorded.writes += 1 }
    nonisolated func beginShutdown() { closing.begin() }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) throws {
        try closing.checkRunning()
        relay.register(changed)
        onObserve()
    }
    func stopObserving() { recorded.stops += 1 }
    func state() -> State { recorded }
    func replaceCurrent(uid: String) { currentUID = uid }
    func releaseOneSlowRead() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
    }
    func finishSlowReads() {
        holdReads = false
        let awaiting = pending
        pending.removeAll()
        awaiting.forEach { $0.resume() }
    }
}

@MainActor
private final class NotificationStressRoutes: PrivateRouting {
    var onChange: (() -> Void)?
    var onRuntimeEvent: ((Int) -> Void)?
    var ownedEvidence: OwnedRouteExitEvidence?
    private(set) var exitInspections = 0
    private(set) var runtimeEvents = 0
    private(set) var shutdownBegins = 0
    private(set) var shutdowns = 0
    private var deliveryTarget: (count: Int, expected: XCTestExpectation)?

    func start() {}
    func stop() {}
    func beginShutdown() { shutdownBegins += 1 }
    func shutdown() { shutdowns += 1 }
    func ownedStreamForExit() -> OwnedRouteExitEvidence? {
        exitInspections += 1
        return ownedEvidence
    }
    func systemOutputDidChange() {
        runtimeEvents += 1
        onRuntimeEvent?(runtimeEvents)
        if let target = deliveryTarget, runtimeEvents >= target.count {
            deliveryTarget = nil
            target.expected.fulfill()
        }
    }
    func snapshot() -> PrivateRouteSnapshot {
        PrivateRouteSnapshot(routes: [], warning: nil, diagnostics: "injected notification stress")
    }
    func select(identifier: String) { XCTFail("A notification must not submit a private selection.") }
    func prepareToLeave() { XCTFail("A notification must not start a user leave transaction.") }
    func completedLeave() { XCTFail("A notification must not finish a user leave transaction.") }

    func waitForDeliveries(_ count: Int) async throws {
        guard runtimeEvents < count else { return }
        let expected = XCTestExpectation(description: "\(count) notification handlers delivered")
        deliveryTarget = (count, expected)
        defer { deliveryTarget = nil }
        try await stressWait([expected])
    }
}

private final class NotificationStressMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var latencySeconds: [Double] = []

    var sampleCount: Int { lock.withLock { latencySeconds.count } }

    func probeMainActor() async {
        let enqueued = ContinuousClock.now
        await MainActor.run {
            let duration = stressSeconds(enqueued.duration(to: .now))
            lock.withLock { latencySeconds.append(duration) }
        }
    }

    func report() -> [String: Any] {
        let samples = lock.withLock { latencySeconds.sorted() }
        guard !samples.isEmpty else { return ["samples": 0] }
        return [
            "samples": samples.count,
            "medianMilliseconds": samples[(samples.count - 1) / 2] * 1_000,
            "p95Milliseconds": samples[Int(Double(samples.count - 1) * 0.95)] * 1_000,
            "maximumMilliseconds": samples.last! * 1_000,
        ]
    }
}

@MainActor
private final class NotificationStressObservation {
    private let expected: XCTestExpectation
    private let predicate: @MainActor () -> Bool
    private var active = true

    init(expected: XCTestExpectation, predicate: @escaping @MainActor () -> Bool) {
        self.expected = expected
        self.predicate = predicate
    }

    func start() {
        guard active else { return }
        let satisfied = withObservationTracking {
            predicate()
        } onChange: { [weak self] in
            Task { @MainActor in self?.start() }
        }
        if satisfied {
            active = false
            expected.fulfill()
        }
    }
    func cancel() { active = false }
}

private enum NotificationStressFailure: Error { case timedOut }

@MainActor
private func stressWait(_ expectations: [XCTestExpectation]) async throws {
    let outcome = await XCTWaiter.fulfillment(of: expectations, timeout: 20)
    guard outcome == .completed else {
        XCTFail("Stress test control point was not reached: \(outcome)")
        throw NotificationStressFailure.timedOut
    }
}

private func stressSeconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}
