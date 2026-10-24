import Foundation
import XCTest
@testable import ToneHop

@MainActor
final class AudioServiceRecoveryTests: XCTestCase {
    func testNewFailedSelectionRetainsItsLeaseWhileOldCleanupReturnsAfterReset() async throws {
        let epoch = AudioServiceEpoch()
        let signal = AudioShutdownSignal()
        let oldCleanup = XCTestExpectation(description: "old cleanup is suspended")
        let newCleanup = XCTestExpectation(description: "new failed request is cleaned with its own lease")
        let worker = RecoveryFailedSelectionWorker(signal: signal, oldCleanup: oldCleanup, newCleanup: newCleanup)
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal, cleanupRetryDelay: .milliseconds(10))
        service.bindServiceEpoch(epoch)
        let old = epoch.capture()

        do { try await service.select(identifier: "receiver"); XCTFail("The injected submission must fail.") }
        catch { XCTAssertEqual((error as NSError).code, 10) }
        let started = await XCTWaiter.fulfillment(of: [oldCleanup], timeout: 2)
        XCTAssertEqual(started, .completed)
        epoch.reset(ifCurrent: old.id)
        service.serviceDidRestart()
        let current = epoch.capture()
        do { try await service.select(identifier: "receiver"); XCTFail("The second injected submission must also fail.") }
        catch { XCTAssertEqual((error as NSError).code, 10) }

        await worker.releaseOldCleanup()
        let completed = await XCTWaiter.fulfillment(of: [newCleanup], timeout: 2)
        XCTAssertEqual(completed, .completed)
        await waitUntil { service.snapshot().routes.first?.canSelect == true }
        let trace = await worker.trace()
        XCTAssertEqual(trace.submissions, [old.id, current.id])
        XCTAssertEqual(trace.cleanupAttempts, [old.id, current.id], "The existing task must override its inherited old lease for the new request.")
        XCTAssertEqual(trace.cleanupWrites, [current.id], "The old operation must remain revoked while the new failure can reconcile.")
        try await service.shutdown()
    }

    func testPrivateSelectionCannotUseNewServiceSnapshotToConfirmItsOldRequest() async throws {
        let epoch = AudioServiceEpoch()
        let worker = RecoveryPrivateWorker()
        let service = PrivateRouteService(worker: worker, shutdownSignal: AudioShutdownSignal())
        service.bindServiceEpoch(epoch)
        let old = epoch.capture()
        let selection = Task { try await service.select(identifier: "receiver") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await worker.readIsHeld), .now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let held = await worker.readIsHeld
        XCTAssertTrue(held)
        epoch.reset(ifCurrent: old.id)
        service.serviceDidRestart()
        let latest = await service.freshSnapshot()
        XCTAssertTrue(latest.routes.first?.isSelected == true)
        await worker.releaseRead()
        do { try await selection.value; XCTFail("A later service's selection cannot confirm the old request.") }
        catch is AudioServiceResetError { }
        let submissions = await worker.submissions
        let leases = await worker.readLeases
        XCTAssertEqual(submissions, 1, "Recovery must not replay Add.")
        XCTAssertEqual(leases, [old.id, epoch.capture().id], "The immutable TaskLocal generation must cross the custom actor executor.")
        try await service.shutdown()
    }

    func testResetCancelsSwitchWaitingBeforeSubmissionAndKeepsItsBoundaryUntilReturn() async throws {
        let hardware = RecoveryHardware()
        let routes = RecoveryRoutes()
        let store = AudioStore(hardware: hardware, routes: routes, pollingInterval: .milliseconds(5))
        var results: [AudioSelectionResult] = []
        store.onSelectionResult = { results.append($0) }
        store.start()
        await waitUntil { !store.devices.isEmpty && hardware.observationAttempts == 1 }
        routes.holdPrepare = true
        store.select(hardware.external)
        await waitUntil { routes.prepareIsHeld }
        hardware.restart()
        await waitUntil { routes.resets == 1 }
        XCTAssertTrue(store.isSwitching, "Cancellation must not declare the old native task returned.")
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertEqual(results.count, 1)
        routes.releasePrepare()
        await waitUntil { !store.isSwitching && !store.volumeTargets.isEmpty }
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertEqual(results.count, 1, "Late return cannot produce a second successful result.")
        XCTAssertGreaterThan(routes.freshReads, 0)
        try await store.shutdown()
    }

    func testResetRejectsSuspendedOldSnapshotAndRebuildsFromFreshPrivateEvidence() async throws {
        let hardware = RecoveryHardware()
        let routes = RecoveryRoutes()
        let store = AudioStore(hardware: hardware, routes: routes, observerRetryDelay: .milliseconds(20), pollingInterval: .milliseconds(5))
        var recovery: [Bool] = []
        store.onServiceRecoveryChange = { recovery.append($0) }
        store.start()
        await waitUntil { store.volumeTargets[hardware.device.id] != nil && hardware.observationAttempts == 1 }
        let original = try XCTUnwrap(store.volumeTargets[hardware.device.id])
        hardware.holdNextSnapshot = true
        store.refresh()
        await waitUntil { hardware.snapshotIsHeld }
        hardware.restart()
        await waitUntil { routes.resets == 1 }
        XCTAssertNil(store.currentDeviceID)
        XCTAssertTrue(store.volumeTargets.isEmpty)
        XCTAssertEqual(recovery, [true])
        hardware.releaseSnapshot()
        await waitUntil { store.volumeTargets[hardware.device.id]?.serviceGeneration == hardware.serviceEpoch?.capture().id }
        await waitUntil { hardware.observationAttempts == 2 }
        let replacement = try XCTUnwrap(store.volumeTargets[hardware.device.id])
        XCTAssertNotEqual(original.generation, replacement.generation)
        XCTAssertNotEqual(original.serviceGeneration, replacement.serviceGeneration)
        XCTAssertGreaterThan(routes.freshReads, 0)
        XCTAssertEqual(recovery, [true, false])
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertEqual(routes.selectionWrites, 0)
        try await store.shutdown()
    }

    func testResetRegistrationFailureRetriesWithoutReplayingWritesAndShutdownClosesLateReset() async throws {
        let hardware = RecoveryHardware()
        let routes = RecoveryRoutes()
        let store = AudioStore(hardware: hardware, routes: routes, observerRetryDelay: .milliseconds(25), pollingInterval: .milliseconds(5))
        store.start()
        await waitUntil { hardware.observationAttempts == 1 && !store.devices.isEmpty }
        let lateCallback = hardware.callback
        hardware.failNextObservations = 1
        let replacement = hardware.restart()
        await waitUntil { hardware.observationAttempts >= 3 }
        XCTAssertEqual(routes.resets, 1)
        lateCallback?(.serviceRestarted(replacement))
        await Task.yield()
        XCTAssertEqual(routes.resets, 1, "A duplicate event cannot start another recovery.")
        XCTAssertTrue(hardware.writes.isEmpty)
        try await store.shutdown()
        let attempts = hardware.observationAttempts
        lateCallback?(.serviceRestarted(UUID()))
        await Task.yield()
        XCTAssertEqual(hardware.observationAttempts, attempts)
        XCTAssertEqual(hardware.stops, 1)
    }

    func testQuitPlanFromBeforeResetCannotSubmitOutputOrCleanup() async throws {
        let hardware = RecoveryHardware()
        let routes = RecoveryRoutes()
        let exit = AudioExitCoordinator(hardware: hardware, routes: routes)
        let plan = try await exit.prepare()
        hardware.restart()
        do { try await exit.complete(plan); XCTFail("A pre-reset confirmation must not authorize new writes.") }
        catch is AudioServiceResetError { }
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertEqual(routes.cleanupWrites, 0)
    }

    func testHiddenResetRestartsFallbackUntilReplacementObservationSucceeds() async throws {
        let hardware = RecoveryHardware()
        let routes = RecoveryRoutes()
        let store = AudioStore(hardware: hardware, routes: routes,
                               observerRetryDelay: .milliseconds(50), pollingInterval: .milliseconds(10))
        store.setPanelVisible(false)
        store.start()
        await waitUntil { !store.devices.isEmpty && routes.periodicObservation.last == false && !store.isRefreshing }
        let beforeReset = hardware.snapshotReads
        hardware.failNextObservations = 2
        hardware.restart()
        await waitUntil { routes.resets == 1 && hardware.observationAttempts >= 2 }
        XCTAssertEqual(routes.periodicObservation.last, true)
        await waitUntil { hardware.snapshotReads >= beforeReset + 3 }
        await waitUntil { hardware.observationAttempts >= 4 && routes.periodicObservation.last == false && !store.isRefreshing }
        let recovered = hardware.snapshotReads
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(hardware.snapshotReads, recovered)
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertEqual(routes.selectionWrites, 0)
        try await store.shutdown()
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), .now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

private actor RecoveryFailedSelectionWorker: PrivateRouteWorking {
    nonisolated var unownedExecutor: UnownedSerialExecutor { AudioRouteExecutor.shared.asUnownedSerialExecutor() }
    private let signal: AudioShutdownSignal
    private let oldCleanup: XCTestExpectation
    private let newCleanup: XCTestExpectation
    private var held: CheckedContinuation<Void, Never>?
    private var submissions: [UUID?] = []
    private var cleanupAttempts: [UUID?] = []
    private var cleanupWrites: [UUID?] = []

    init(signal: AudioShutdownSignal, oldCleanup: XCTestExpectation, newCleanup: XCTestExpectation) {
        self.signal = signal
        self.oldCleanup = oldCleanup
        self.newCleanup = newCleanup
    }
    func submit(identifier: String) throws {
        submissions.append(AudioServiceOperation.lease?.id)
        throw NSError(domain: "dev.dengziyi.ToneHop.RetainedSystemAudio", code: 10)
    }
    func read() -> PrivateRouteSnapshot {
        .init(routes: [.init(identifier: "receiver", name: "Receiver", uid: "stream", isSelected: false,
                            canSelect: !cleanupWrites.isEmpty, transport: "airplay")], warning: nil,
              diagnostics: cleanupWrites.isEmpty ? "cleanup pending" : "cleanup completed")
    }
    func finishFailedSelection() async throws {
        let lease = AudioServiceOperation.lease
        cleanupAttempts.append(lease?.id)
        if cleanupAttempts.count == 1 {
            await withCheckedContinuation { continuation in
                held = continuation
                oldCleanup.fulfill()
            }
        }
        guard signal.performIfRunning(servicePermit: lease?.permit, { cleanupWrites.append(lease?.id) }) else {
            throw AudioServiceResetError.serviceChanged
        }
        newCleanup.fulfill()
    }
    func releaseOldCleanup() { let pending = held; held = nil; pending?.resume() }
    func trace() -> (submissions: [UUID?], cleanupAttempts: [UUID?], cleanupWrites: [UUID?]) {
        (submissions, cleanupAttempts, cleanupWrites)
    }
    func prepareToLeave() {}
    func completedLeave() {}
    func stop() {}
}

private actor RecoveryPrivateWorker: PrivateRouteWorking {
    nonisolated var unownedExecutor: UnownedSerialExecutor { AudioRouteExecutor.shared.asUnownedSerialExecutor() }
    private var shouldHoldRead = false
    private var held: CheckedContinuation<Void, Never>?
    var readIsHeld: Bool { held != nil }
    private(set) var submissions = 0
    private(set) var readLeases: [UUID?] = []
    func submit(identifier: String) async throws { submissions += 1; shouldHoldRead = true }
    func read() async -> PrivateRouteSnapshot {
        readLeases.append(AudioServiceOperation.lease?.id)
        if shouldHoldRead {
            shouldHoldRead = false
            await withCheckedContinuation { held = $0 }
        }
        return .init(routes: [.init(identifier: "receiver", name: "Receiver", uid: "stream", isSelected: true,
                                    transportKind: .airplay, selectionCapability: .retainedAirPlay)], warning: nil, diagnostics: "fixture")
    }
    func releaseRead() { let pending = held; held = nil; pending?.resume() }
    func prepareToLeave() async throws {}
    func completedLeave() async throws {}
    func finishFailedSelection() async throws {}
    func stop() async throws {}
}

@MainActor
private final class RecoveryHardware: AudioHardwareProviding {
    nonisolated let serviceEpoch: AudioServiceEpoch? = AudioServiceEpoch()
    let device = AudioDevice(id: "hal:recovery-speaker", name: "Speaker", transport: .speaker,
                             backend: .coreAudio(uid: "recovery-speaker"), shortcutTarget: .hal(uid: "recovery-speaker"))
    let external = AudioDevice(id: "hal:recovery-usb", name: "USB", transport: .usb,
                               backend: .coreAudio(uid: "recovery-usb"), shortcutTarget: .hal(uid: "recovery-usb"))
    var observationAttempts = 0
    var snapshotReads = 0
    var failNextObservations = 0
    var callback: (@Sendable (AudioHardwareEvent) -> Void)?
    var writes: [String] = []
    var stops = 0
    var holdNextSnapshot = false
    private var heldSnapshot: CheckedContinuation<Void, Never>?
    var snapshotIsHeld: Bool { heldSnapshot != nil }
    func snapshot() async throws -> CoreAudioSnapshot {
        snapshotReads += 1
        let captured = CoreAudioSnapshot(devices: [device, external], currentDeviceID: device.id,
            systemSoundDeviceID: device.id, warnings: [], confirmedDeviceObjects: ["recovery-speaker": 7, "recovery-usb": 8],
            serviceGeneration: serviceEpoch?.capture().id)
        if holdNextSnapshot {
            holdNextSnapshot = false
            await withCheckedContinuation { heldSnapshot = $0 }
        }
        return captured
    }
    func releaseSnapshot() { let pending = heldSnapshot; heldSnapshot = nil; pending?.resume() }
    @discardableResult func restart() -> UUID {
        let epoch = serviceEpoch!
        let next = epoch.reset(ifCurrent: epoch.capture().id) ?? epoch.capture().id
        callback?(.serviceRestarted(next))
        return next
    }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws {}
    func observeEvents(_ changed: @escaping @Sendable (AudioHardwareEvent) -> Void) async throws {
        observationAttempts += 1
        if failNextObservations > 0 { failNextObservations -= 1; throw AudioServiceError.unavailable("injected install failure") }
        callback = changed
    }
    func select(uid: String) async throws { writes.append(uid) }
    func builtInSpeaker() async throws -> AudioDevice { device }
    nonisolated func beginShutdown() { serviceEpoch?.close() }
    func stopObserving() async { stops += 1; callback = nil }
}

@MainActor
private final class RecoveryRoutes: PrivateRouting {
    var onChange: (() -> Void)?
    var periodicObservation: [Bool] = []
    var resets = 0
    var freshReads = 0
    var selectionWrites = 0
    var cleanupWrites = 0
    var holdPrepare = false
    private var prepared: CheckedContinuation<Void, Never>?
    var prepareIsHeld: Bool { prepared != nil }
    func start() {}
    func setPeriodicObservation(_ active: Bool) { periodicObservation.append(active) }
    func stop() {}
    func beginShutdown() {}
    func serviceDidRestart() { resets += 1 }
    func snapshot() -> PrivateRouteSnapshot { .init(routes: [], warning: nil, diagnostics: "fixture") }
    func freshSnapshot() async -> PrivateRouteSnapshot { freshReads += 1; return snapshot() }
    func select(identifier: String) async throws { selectionWrites += 1 }
    func prepareToLeave() async throws {
        if holdPrepare { holdPrepare = false; await withCheckedContinuation { prepared = $0 } }
    }
    func releasePrepare() { let pending = prepared; prepared = nil; pending?.resume() }
    func completedLeave() async throws { cleanupWrites += 1 }
    func ownedStreamForExit() async throws -> OwnedRouteExitEvidence? {
        .init(receiverID: "owned-fixture", streamUID: "stream-fixture", name: "Fixture")
    }
}
