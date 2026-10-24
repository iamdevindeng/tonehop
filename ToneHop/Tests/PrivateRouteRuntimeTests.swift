import Foundation
import XCTest
@testable import ToneHop

@MainActor
final class PrivateRouteRuntimeTests: XCTestCase {
    func testConcurrentShutdownWaitsForRuntimeAndStopsWorkerOnceWithoutWrites() async throws {
        let signal = AudioShutdownSignal()
        let runtimeStarted = XCTestExpectation(description: "runtime operation is suspended")
        let worker = RuntimeRouteWorker(signal: signal, suspendFirstAttempt: true, onAttempt: { attempt in
            if attempt == 1 { runtimeStarted.fulfill() }
        })
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal)
        service.systemOutputDidChange()
        let running = await XCTWaiter.fulfillment(of: [runtimeStarted], timeout: 2)
        XCTAssertEqual(running, .completed)

        let shutdownStarted = XCTestExpectation(description: "both callers request shutdown")
        shutdownStarted.expectedFulfillmentCount = 2
        let first = Task {
            shutdownStarted.fulfill()
            try await service.shutdown()
        }
        let second = Task {
            shutdownStarted.fulfill()
            try await service.shutdown()
        }
        let closing = await XCTWaiter.fulfillment(of: [shutdownStarted], timeout: 2)
        XCTAssertEqual(closing, .completed)
        XCTAssertTrue(signal.isShuttingDown)
        XCTAssertFalse(signal.performIfRunning { XCTFail("Service shutdown left ordinary writes open.") })
        let pending = await worker.state()
        XCTAssertEqual(pending.stops, 0, "The worker must outlive the runtime operation already in flight.")
        await worker.releaseFirstAttempt()
        try await first.value
        try await second.value
        try await service.shutdown()

        let finished = await worker.state()
        XCTAssertEqual(finished.stops, 1)
        XCTAssertEqual(finished.attempts, 1)
        XCTAssertEqual(finished.reads, 0)
        XCTAssertEqual(finished.submissions, 0)
        XCTAssertEqual(finished.explicitLeaveCalls, 0)
        XCTAssertEqual(finished.failedSelectionCalls, 0)
    }

    func testSystemOutputEventReconcilesBeforePublishingWithoutSelectingARoute() async throws {
        let signal = AudioShutdownSignal()
        let worker = RuntimeRouteWorker(signal: signal)
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal)
        let published = XCTestExpectation(description: "external output event publishes reconciled state")
        service.onChange = { published.fulfill() }

        service.systemOutputDidChange()
        let result = await XCTWaiter.fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(result, .completed)

        let state = await worker.state()
        XCTAssertEqual(state.events, ["reconcile:1", "read"])
        XCTAssertEqual(service.snapshot().diagnostics, "complete:1")
        XCTAssertEqual(state.submissions, 0)
        XCTAssertEqual(state.explicitLeaveCalls, 0)
        XCTAssertEqual(state.failedSelectionCalls, 0)
        try await service.shutdown()
    }

    func testEventBurstsCoalesceAndAnEventDuringReconciliationIsNotLost() async throws {
        let signal = AudioShutdownSignal()
        let firstAttempt = XCTestExpectation(description: "first runtime attempt is suspended")
        let secondPublished = XCTestExpectation(description: "event during runtime work gets another pass")
        let worker = RuntimeRouteWorker(signal: signal, suspendFirstAttempt: true, onAttempt: { attempt in
            if attempt == 1 { firstAttempt.fulfill() }
        })
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal)
        service.onChange = {
            if service.snapshot().diagnostics == "complete:2" { secondPublished.fulfill() }
        }

        for _ in 0..<20 { service.systemOutputDidChange() }
        let started = await XCTWaiter.fulfillment(of: [firstAttempt], timeout: 2)
        XCTAssertEqual(started, .completed)
        for _ in 0..<20 { service.systemOutputDidChange() }
        await worker.releaseFirstAttempt()
        let finished = await XCTWaiter.fulfillment(of: [secondPublished], timeout: 2)
        XCTAssertEqual(finished, .completed)
        try await service.shutdown()

        let state = await worker.state()
        XCTAssertEqual(state.attempts, 2, "Each burst should request one pass, including the burst received in flight.")
        XCTAssertEqual(state.maximumConcurrentAttempts, 1, "Only one runtime pump may enter the reentrant worker.")
        XCTAssertEqual(state.submissions, 0)
    }

    func testPendingCallbackRetriesUntilRecoveryWithoutAnotherSystemEvent() async throws {
        let signal = AudioShutdownSignal()
        let warning = "来源读取不完整"
        let worker = RuntimeRouteWorker(signal: signal, outcomes: [.pending, .pending, .complete], warning: warning)
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal,
                                          cleanupRetryDelay: .milliseconds(10))
        let recovered = XCTestExpectation(description: "pending native callback eventually publishes recovery")
        var publishedWarnings: [String?] = []
        service.onChange = {
            publishedWarnings.append(service.snapshot().warning)
            if service.snapshot().diagnostics == "complete:3" { recovered.fulfill() }
        }

        service.systemOutputDidChange()
        let result = await XCTWaiter.fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(result, .completed)
        try await service.shutdown()

        let state = await worker.state()
        XCTAssertEqual(state.attempts, 3)
        XCTAssertEqual(state.reads, 3, "Pending state and the final recovery must all be read back.")
        XCTAssertEqual(state.submissions, 0)
        XCTAssertEqual(state.maximumConcurrentAttempts, 1)
        XCTAssertEqual(publishedWarnings, [warning, warning, warning], "Pending retries must preserve source warnings without adding operation errors.")
    }

    func testTerminalFailurePublishesStateWithoutATightRetryLoop() async throws {
        let signal = AudioShutdownSignal()
        let published = XCTestExpectation(description: "terminal native result is published")
        let repeated = XCTestExpectation(description: "terminal failure must await a fresh runtime trigger")
        repeated.isInverted = true
        let worker = RuntimeRouteWorker(signal: signal, outcomes: [.terminal], onAttempt: { attempt in
            if attempt > 1 { repeated.fulfill() }
        })
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal,
                                          cleanupRetryDelay: .milliseconds(10))
        service.onChange = { published.fulfill() }

        service.systemOutputDidChange()
        let first = await XCTWaiter.fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(first, .completed)
        let quiet = await XCTWaiter.fulfillment(of: [repeated], timeout: 0.08)
        XCTAssertEqual(quiet, .completed)
        XCTAssertEqual(service.snapshot().diagnostics, "terminal:1")
        XCTAssertNil(service.snapshot().warning, "Background operation errors must remain out of panel warnings.")
        try await service.shutdown()
        let state = await worker.state()
        XCTAssertEqual(state.attempts, 1)
    }

    func testTerminalReconciliationFailurePreservesSourceWarningsFromTheRead() async throws {
        let signal = AudioShutdownSignal()
        let warning = "来源健康提示\n设备能力提示\n目录提示"
        let worker = RuntimeRouteWorker(signal: signal, outcomes: [.terminal], warning: warning)
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal)
        let published = XCTestExpectation(description: "source evidence remains visible after a background operation fails")
        service.onChange = { published.fulfill() }

        service.systemOutputDidChange()
        let result = await XCTWaiter.fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(service.snapshot().warning, warning)
        XCTAssertEqual(service.snapshot().diagnostics, "terminal:1")
        let state = await worker.state()
        XCTAssertEqual(state.events, ["reconcile:1", "read"])
        XCTAssertEqual(state.submissions, 0)
        try await service.shutdown()
    }

    func testShutdownCancelsPendingRetryAndRejectsFurtherEvents() async throws {
        let signal = AudioShutdownSignal()
        let published = XCTestExpectation(description: "pending state is published before shutdown")
        let worker = RuntimeRouteWorker(signal: signal, outcomes: [.pending])
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal,
                                          cleanupRetryDelay: .milliseconds(50), runtimePollDelay: .milliseconds(10))
        var publications = 0
        service.onChange = {
            publications += 1
            published.fulfill()
        }

        service.systemOutputDidChange()
        let first = await XCTWaiter.fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(first, .completed)
        try await service.shutdown()
        let publicationsAtShutdown = publications
        for _ in 0..<20 { service.systemOutputDidChange() }
        service.refresh()
        service.start()
        try await Task.sleep(for: .milliseconds(120))

        let state = await worker.state()
        XCTAssertEqual(state.attempts, 1)
        XCTAssertEqual(state.reads, 1)
        XCTAssertEqual(state.stops, 1)
        XCTAssertEqual(state.submissions, 0)
        XCTAssertEqual(publications, publicationsAtShutdown)
    }

    func testShutdownDiscardsAnInFlightRuntimeResultAndQueuedEvent() async throws {
        let signal = AudioShutdownSignal()
        let firstAttempt = XCTestExpectation(description: "runtime work is in flight")
        let worker = RuntimeRouteWorker(signal: signal, suspendFirstAttempt: true, onAttempt: { attempt in
            if attempt == 1 { firstAttempt.fulfill() }
        })
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal)
        var publications = 0
        service.onChange = { publications += 1 }

        service.systemOutputDidChange()
        let started = await XCTWaiter.fulfillment(of: [firstAttempt], timeout: 2)
        XCTAssertEqual(started, .completed)
        service.systemOutputDidChange()
        service.beginShutdown()
        await worker.releaseFirstAttempt()
        try await service.shutdown()
        // Allow the cancelled pump's continuation to return to the MainActor.
        await Task.yield()

        let state = await worker.state()
        XCTAssertEqual(state.attempts, 1)
        XCTAssertEqual(state.reads, 0)
        XCTAssertEqual(state.stops, 1)
        XCTAssertEqual(publications, 0)
    }

    func testRefreshOnlyReadsAndDoesNotReconcileRuntimeState() async throws {
        let signal = AudioShutdownSignal()
        let worker = RuntimeRouteWorker(signal: signal)
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal)
        let published = XCTestExpectation(description: "plain refresh publishes its read")
        service.onChange = { published.fulfill() }

        service.refresh()
        let result = await XCTWaiter.fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(result, .completed)
        let state = await worker.state()
        XCTAssertEqual(state.events, ["read"])
        XCTAssertEqual(state.attempts, 0)
        XCTAssertEqual(state.submissions, 0)
        try await service.shutdown()
    }

    func testOlderRefreshReadCannotOverwriteANewerRuntimePublication() async throws {
        let signal = AudioShutdownSignal()
        let firstRead = XCTestExpectation(description: "plain refresh read is suspended")
        let firstReadReturned = XCTestExpectation(description: "older read eventually returns")
        let newerPublished = XCTestExpectation(description: "runtime publishes its newer read")
        let stalePublished = XCTestExpectation(description: "older refresh must not replace the runtime result")
        stalePublished.isInverted = true
        let worker = RuntimeRouteWorker(signal: signal, suspendFirstRead: true, onRead: { read in
            if read == 1 { firstRead.fulfill() }
        }, onReadReturned: { read in
            if read == 1 { firstReadReturned.fulfill() }
        })
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal)
        service.onChange = {
            switch service.snapshot().diagnostics {
            case "complete:1": newerPublished.fulfill()
            case "unreconciled": stalePublished.fulfill()
            default: break
            }
        }

        service.refresh()
        let reading = await XCTWaiter.fulfillment(of: [firstRead], timeout: 2)
        XCTAssertEqual(reading, .completed)
        service.systemOutputDidChange()
        let newer = await XCTWaiter.fulfillment(of: [newerPublished], timeout: 2)
        XCTAssertEqual(newer, .completed)
        await worker.releaseFirstRead()
        let returned = await XCTWaiter.fulfillment(of: [firstReadReturned], timeout: 2)
        XCTAssertEqual(returned, .completed)
        let quiet = await XCTWaiter.fulfillment(of: [stalePublished], timeout: 0.08)
        XCTAssertEqual(quiet, .completed)

        XCTAssertEqual(service.snapshot().diagnostics, "complete:1")
        let state = await worker.state()
        XCTAssertEqual(state.events, ["read", "reconcile:1", "read"])
        XCTAssertEqual(state.reads, 2)
        try await service.shutdown()
    }

    func testStartingObservationDuringAnExternalEventKeepsThatPumpAndItsFollowUp() async throws {
        let signal = AudioShutdownSignal()
        let firstAttempt = XCTestExpectation(description: "external event reconciliation is suspended")
        let firstPublished = XCTestExpectation(description: "external event survives starting observation")
        let secondPublished = XCTestExpectation(description: "initial observation event is processed by the same pump")
        let prematurePublication = XCTestExpectation(description: "observation must not read ahead of the suspended reconciliation")
        prematurePublication.isInverted = true
        let worker = RuntimeRouteWorker(signal: signal, suspendFirstAttempt: true, onAttempt: { attempt in
            if attempt == 1 { firstAttempt.fulfill() }
        })
        // Keep the second timer tick outside the test window: the follow-up
        // must come from start's first observation event, not a later poll.
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal, runtimePollDelay: .seconds(60))
        service.onChange = { prematurePublication.fulfill() }

        service.systemOutputDidChange()
        let started = await XCTWaiter.fulfillment(of: [firstAttempt], timeout: 2)
        XCTAssertEqual(started, .completed)
        service.start()
        let held = await XCTWaiter.fulfillment(of: [prematurePublication], timeout: 0.04)
        XCTAssertEqual(held, .completed)
        service.onChange = {
            switch service.snapshot().diagnostics {
            case "complete:1": firstPublished.fulfill()
            case "complete:2": secondPublished.fulfill()
            default: break
            }
        }
        await worker.releaseFirstAttempt()
        let result = await XCTWaiter.fulfillment(of: [firstPublished, secondPublished], timeout: 2,
                                                enforceOrder: true)
        XCTAssertEqual(result, .completed)
        try await service.shutdown()

        let state = await worker.state()
        XCTAssertEqual(state.attempts, 2)
        XCTAssertEqual(state.events, ["reconcile:1", "read", "reconcile:2", "read"])
        XCTAssertEqual(state.maximumConcurrentAttempts, 1)
    }

    func testStartReconcilesImmediatelyAndOnTheObservationPeriod() async throws {
        let signal = AudioShutdownSignal()
        let worker = RuntimeRouteWorker(signal: signal)
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal,
                                          runtimePollDelay: .milliseconds(15))
        let firstPublished = XCTestExpectation(description: "start includes initial reconciliation")
        let secondPublished = XCTestExpectation(description: "periodic observation reconciles again")
        service.onChange = {
            switch service.snapshot().diagnostics {
            case "complete:1": firstPublished.fulfill()
            case "complete:2": secondPublished.fulfill()
            default: break
            }
        }

        service.start()
        service.start()
        let result = await XCTWaiter.fulfillment(of: [firstPublished, secondPublished], timeout: 2,
                                                enforceOrder: true)
        XCTAssertEqual(result, .completed)
        try await service.shutdown()

        let state = await worker.state()
        XCTAssertGreaterThanOrEqual(state.attempts, 2)
        XCTAssertEqual(Array(state.events.prefix(4)), ["reconcile:1", "read", "reconcile:2", "read"])
        XCTAssertEqual(state.maximumConcurrentAttempts, 1)
        XCTAssertEqual(state.submissions, 0)
    }
    func testInactivePrivateObservationStaysIdleForTenSecondsAndStillHandlesOutputEvents() async throws {
        let signal = AudioShutdownSignal()
        let worker = RuntimeRouteWorker(signal: signal)
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal,
                                          runtimePollDelay: .milliseconds(25))
        service.setPeriodicObservation(false)
        service.start()
        await waitUntil { service.snapshot().diagnostics == "complete:1" }
        try await Task.sleep(for: .seconds(10))
        let idle = await worker.state()
        XCTAssertEqual(idle.attempts, 1)
        XCTAssertEqual(idle.reads, 1)

        service.setPeriodicObservation(false)
        service.systemOutputDidChange()
        await waitUntil { service.snapshot().diagnostics == "complete:2" }
        service.setPeriodicObservation(true)
        service.setPeriodicObservation(false)
        service.setPeriodicObservation(true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (await worker.state()).attempts < 5, .now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let active = await worker.state()
        XCTAssertGreaterThanOrEqual(active.attempts, 5, "The replacement monitor must keep polling.")
        service.setPeriodicObservation(false)
        try await Task.sleep(for: .milliseconds(100))
        let settled = await worker.state()
        try await Task.sleep(for: .milliseconds(150))
        let stopped = await worker.state()
        XCTAssertEqual(stopped.attempts, settled.attempts, "An old cancelled timer must not survive rapid toggles.")
        XCTAssertEqual(stopped.reads, settled.reads)
        XCTAssertEqual(stopped.submissions, 0)
        XCTAssertEqual(stopped.maximumConcurrentAttempts, 1)
        try await service.shutdown()
    }

    func testPrivateDeactivationReconcilesExactlyOnceAndReactivationIsImmediate() async throws {
        let signal = AudioShutdownSignal()
        let worker = RuntimeRouteWorker(signal: signal)
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal, runtimePollDelay: .seconds(30))
        service.start()
        await waitUntil { service.snapshot().diagnostics == "complete:1" }
        service.setPeriodicObservation(false)
        await waitUntil { service.snapshot().diagnostics == "complete:2" }
        service.setPeriodicObservation(false)
        try await Task.sleep(for: .milliseconds(100))
        let hidden = await worker.state()
        XCTAssertEqual(hidden.attempts, 2)
        XCTAssertEqual(hidden.reads, 2)

        service.setPeriodicObservation(true)
        await waitUntil { service.snapshot().diagnostics == "complete:3" }
        let resumed = await worker.state()
        XCTAssertEqual(resumed.attempts, 3, "The first active tick must not wait for the 30-second interval.")
        XCTAssertEqual(resumed.reads, 3)
        try await service.shutdown()
    }

    func testPrivateDeactivationPreservesInFlightReconciliationAndItsFollowUp() async throws {
        let signal = AudioShutdownSignal()
        let firstAttempt = XCTestExpectation(description: "native reconciliation is in flight")
        let worker = RuntimeRouteWorker(signal: signal, suspendFirstAttempt: true, onAttempt: { attempt in
            if attempt == 1 { firstAttempt.fulfill() }
        })
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal, runtimePollDelay: .seconds(30))
        service.start()
        let started = await XCTWaiter.fulfillment(of: [firstAttempt], timeout: 2)
        XCTAssertEqual(started, .completed)
        service.setPeriodicObservation(false)
        await worker.releaseFirstAttempt()
        await waitUntil { service.snapshot().diagnostics == "complete:2" }
        let finished = await worker.state()
        XCTAssertEqual(finished.events, ["reconcile:1", "read", "reconcile:2", "read"])
        XCTAssertEqual(finished.maximumConcurrentAttempts, 1)
        XCTAssertEqual(finished.submissions, 0)
        try await service.shutdown()
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), .now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

private actor RuntimeRouteWorker: PrivateRouteWorking {
    enum Outcome: String, Sendable { case pending, complete, terminal }

    struct State: Sendable {
        var attempts = 0
        var maximumConcurrentAttempts = 0
        var reads = 0
        var submissions = 0
        var explicitLeaveCalls = 0
        var failedSelectionCalls = 0
        var stops = 0
        var events: [String] = []
    }

    private let signal: AudioShutdownSignal
    private let outcomes: [Outcome]
    private let warning: String?
    private let suspendFirstAttempt: Bool
    private let suspendFirstRead: Bool
    private let onRead: @Sendable (Int) -> Void
    private let onReadReturned: @Sendable (Int) -> Void
    private let onAttempt: @Sendable (Int) -> Void
    private var suspended: CheckedContinuation<Void, Never>?
    private var suspendedRead: CheckedContinuation<Void, Never>?
    private var activeAttempts = 0
    private var diagnostics = "unreconciled"
    private var recorded = State()

    init(signal: AudioShutdownSignal, outcomes: [Outcome] = [.complete],
         warning: String? = nil,
         suspendFirstAttempt: Bool = false, suspendFirstRead: Bool = false,
         onRead: @escaping @Sendable (Int) -> Void = { _ in },
         onReadReturned: @escaping @Sendable (Int) -> Void = { _ in },
         onAttempt: @escaping @Sendable (Int) -> Void = { _ in }) {
        precondition(!outcomes.isEmpty)
        self.signal = signal
        self.outcomes = outcomes
        self.warning = warning
        self.suspendFirstAttempt = suspendFirstAttempt
        self.suspendFirstRead = suspendFirstRead
        self.onRead = onRead
        self.onReadReturned = onReadReturned
        self.onAttempt = onAttempt
    }

    func read() async -> PrivateRouteSnapshot {
        recorded.reads += 1
        let read = recorded.reads
        recorded.events.append("read")
        // Capture at read entry so an intentionally delayed response retains
        // the older state even if another actor job reconciles in the meantime.
        let snapshot = PrivateRouteSnapshot(routes: [], warning: warning, diagnostics: diagnostics)
        onRead(read)
        if suspendFirstRead, read == 1 {
            await withCheckedContinuation { suspendedRead = $0 }
        }
        onReadReturned(read)
        return snapshot
    }

    func reconcileRuntimeState() async throws {
        try Task.checkCancellation()
        try signal.checkRunning()
        recorded.attempts += 1
        let attempt = recorded.attempts
        activeAttempts += 1
        recorded.maximumConcurrentAttempts = max(recorded.maximumConcurrentAttempts, activeAttempts)
        recorded.events.append("reconcile:\(attempt)")
        defer { activeAttempts -= 1 }
        onAttempt(attempt)
        if suspendFirstAttempt, attempt == 1 {
            await withCheckedContinuation { suspended = $0 }
        }
        try Task.checkCancellation()
        try signal.checkRunning()
        let outcome = outcomes[min(attempt - 1, outcomes.count - 1)]
        diagnostics = "\(outcome.rawValue):\(attempt)"
        switch outcome {
        case .complete: return
        case .pending: throw failure(code: 24)
        case .terminal: throw failure(code: 25)
        }
    }

    func submit(identifier: String) { recorded.submissions += 1 }
    func prepareToLeave() { recorded.explicitLeaveCalls += 1 }
    func completedLeave() { recorded.explicitLeaveCalls += 1 }
    func finishFailedSelection() { recorded.failedSelectionCalls += 1 }
    func stop() { recorded.stops += 1 }

    func releaseFirstAttempt() {
        let pending = suspended
        suspended = nil
        pending?.resume()
    }

    func releaseFirstRead() {
        let pending = suspendedRead
        suspendedRead = nil
        pending?.resume()
    }

    func state() -> State { recorded }

    private func failure(code: Int) -> NSError {
        NSError(domain: "dev.dengziyi.ToneHop.RetainedSystemAudio", code: code,
                userInfo: [NSLocalizedDescriptionKey: "Injected runtime reconciliation \(code)"])
    }
}
