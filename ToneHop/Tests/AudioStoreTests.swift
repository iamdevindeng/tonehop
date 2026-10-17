import Foundation
import Observation
import XCTest
@testable import ToneHop

@MainActor
final class AudioStoreTests: XCTestCase {
    func testNativeExistingStreamUnconfirmedOutcomeUsesTypedPresentationWithoutRetry() async throws {
        let reason = "系统未完整确认接收器选择。"
        for (domain, code, unconfirmed) in [
            (THRetainedAudioErrorDomain, THRetainedAudioError.capturedSelectionUnconfirmed.rawValue, true),
            (THRetainedAudioErrorDomain, THRetainedAudioError.capturedStreamChanged.rawValue, false),
            ("another-domain", THRetainedAudioError.capturedSelectionUnconfirmed.rawValue, false),
        ] {
            let local = device(uid: "local")
            let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .leaveOutputUnchanged)
            let recovery = PrivateAudioRoute(identifier: "bedroom", name: "Bedroom", uid: "old-stream",
                isSelected: false, transportKind: .airplay, selectionCapability: .existingSystemStream)
            let worker = SelectionPresentationWorker(route: recovery,
                rejection: NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: reason]))
            let routes = PrivateRouteService(worker: worker, shutdownSignal: AudioShutdownSignal())
            _ = await routes.freshSnapshot()
            let store = AudioStore(hardware: hardware, routes: routes)
            defer { store.stop() }
            store.refresh()
            await waitForState("initial recovery route") { store.devices.count == 2 }
            let target = try XCTUnwrap(store.devices.first { $0.id == "route:bedroom" })
            store.select(target)
            await waitForState("native result has settled") { !store.isSwitching && store.feedbackKind == .failure }

            XCTAssertEqual(store.feedback, reason)
            XCTAssertEqual(store.presentationFeedback, unconfirmed ? expectedLocalized("Switching result not yet confirmed", "暂未确认切换结果") : expectedLocalized("Could not switch to Bedroom", "无法切换到 Bedroom"))
            XCTAssertEqual(store.failureEvent?.message, store.presentationFeedback)
            XCTAssertEqual(store.currentDeviceID, local.id)
            _ = await routes.freshSnapshot()
            let trace = await worker.trace()
            XCTAssertEqual(trace.requests, ["bedroom"], "Failure refresh cannot replay recovery.")
            let halWrites = await hardware.selectedUIDs()
            XCTAssertTrue(halWrites.isEmpty, "Private receiver recovery stays inside its selected strategy.")
            try await store.shutdown()
        }
    }

    func testPrivateServiceReadbackTimeoutPreservesUnconfirmedPresentation() async throws {
        let local = device(uid: "local")
        let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .leaveOutputUnchanged)
        let worker = SelectionPresentationWorker(route: receiver(selected: false))
        let routes = PrivateRouteService(worker: worker, shutdownSignal: AudioShutdownSignal())
        _ = await routes.freshSnapshot()
        // Exercise the service's real 12-second deadline, before the Store's
        // independent timeout, without changing production timing for a test.
        let store = AudioStore(hardware: hardware, routes: routes, timeout: .seconds(30))
        defer { store.stop() }
        store.refresh()
        await waitForState("initial private route") { store.devices.count == 2 }
        let target = try XCTUnwrap(store.devices.first { $0.id == "route:bedroom" })
        let completed = expectation(description: "private service exhausts its readback deadline")
        var outcomes: [AudioSelectionOutcome] = []
        store.onSelectionResult = { result in outcomes.append(result.outcome); completed.fulfill() }

        store.select(target)
        await fulfillment(of: [completed], timeout: 20)
        await waitForState("selection has settled") { !store.isSwitching }

        let reason = expectedLocalized("AirPlay switching timed out. The system did not confirm the target device.",
                                       "AirPlay 切换超时，系统未确认目标设备。")
        XCTAssertEqual(store.feedback, reason)
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Switching result not yet confirmed", "暂未确认切换结果"))
        XCTAssertEqual(store.failureEvent?.message, expectedLocalized("Switching result not yet confirmed", "暂未确认切换结果"))
        XCTAssertEqual(store.currentDeviceID, local.id)
        XCTAssertEqual(outcomes, [.failed(reason)])
        let failure = store.failureEvent
        let readStarted = expectation(description: "ordinary refresh after unconfirmed selection")
        let read = await hardware.suspendNextSnapshot { readStarted.fulfill() }
        store.refresh()
        await fulfillment(of: [readStarted], timeout: 2)
        await hardware.releaseSnapshot(read)
        await waitForState("ordinary refresh has settled") { !store.isRefreshing }
        XCTAssertEqual(store.feedback, reason)
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Switching result not yet confirmed", "暂未确认切换结果"))
        XCTAssertEqual(store.failureEvent, failure, "Redisplaying uncertainty must not replay its warning event.")
        let trace = await worker.trace()
        XCTAssertEqual(trace.requests, ["bedroom"])
        XCTAssertEqual(trace.accepted, 1, "Readback failure and refresh must not resubmit the selection.")
        let halWrites = await hardware.selectedUIDs()
        XCTAssertTrue(halWrites.isEmpty)
        try await store.shutdown()
    }

    func testPrivateServiceRejectionDoesNotInferUncertaintyFromErrorText() async throws {
        let local = device(uid: "local")
        let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .leaveOutputUnchanged)
        // Deliberately timeout-like wording: classification must follow the typed
        // backend outcome, not a localized substring or entry into a strategy.
        let reason = "AirPlay 切换超时，系统未确认目标设备。"
        let worker = SelectionPresentationWorker(route: receiver(selected: false), rejection: AudioServiceError.unavailable(reason))
        let routes = PrivateRouteService(worker: worker, shutdownSignal: AudioShutdownSignal())
        _ = await routes.freshSnapshot()
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { store.stop() }
        store.refresh()
        await waitForState("initial private route") { store.devices.count == 2 }
        let target = try XCTUnwrap(store.devices.first { $0.id == "route:bedroom" })
        var outcomes: [AudioSelectionOutcome] = []
        store.onSelectionResult = { outcomes.append($0.outcome) }

        store.select(target)
        await waitForState("private request is rejected") { !store.isSwitching && store.feedbackKind == .failure }

        XCTAssertEqual(store.feedback, reason)
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Could not switch to Bedroom", "无法切换到 Bedroom"))
        XCTAssertEqual(store.failureEvent?.message, expectedLocalized("Could not switch to Bedroom", "无法切换到 Bedroom"))
        XCTAssertEqual(store.currentDeviceID, local.id)
        XCTAssertEqual(outcomes, [.failed(reason)])
        let trace = await worker.trace()
        XCTAssertEqual(trace.requests, ["bedroom"])
        XCTAssertEqual(trace.accepted, 0)
        let halWrites = await hardware.selectedUIDs()
        XCTAssertTrue(halWrites.isEmpty)
        try await store.shutdown()
    }

    func testSuccessfulWriteWithoutMatchingReadbackTimesOutWithoutReportingSuccess() async {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id, behavior: .leaveOutputUnchanged)
        let routes = FakePrivateRouting()
        let store = AudioStore(hardware: hardware, routes: routes, timeout: .milliseconds(10))
        defer { store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }

        store.select(target)
        await waitForState("failed readback finishes") { !store.isSwitching && store.feedbackKind == .failure }

        XCTAssertEqual(store.currentDeviceID, first.id)
        XCTAssertFalse(store.feedback.hasPrefix(expectedLocalized("Switched to", "已切换到")))
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Switching result not yet confirmed", "暂未确认切换结果"))
        XCTAssertEqual(store.failureEvent?.message, expectedLocalized("Switching result not yet confirmed", "暂未确认切换结果"))
        let selections = await hardware.selectedUIDs()
        XCTAssertEqual(selections, ["target"], "A successful request return is not proof of a routing change.")
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
    }

    func testConsecutiveClicksSendOnlyOneSwitchRequest() async {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let ignored = device(uid: "ignored")
        let hardware = FakeAudioHardware(devices: [first, target, ignored], current: first.id, behavior: .confirmRequestedOutput)
        let routes = FakePrivateRouting()
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 3 }

        // Both clicks occur before the task can complete; the second must not queue.
        store.select(target)
        XCTAssertTrue(store.isSwitching)
        store.select(ignored)
        await waitForState("first request confirms") { !store.isSwitching && store.feedbackKind == .success }

        let selections = await hardware.selectedUIDs()
        XCTAssertEqual(selections, ["target"])
        XCTAssertEqual(store.currentDeviceID, target.id)
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Click to switch. Shortcuts need ⌘ or ⌃", "点按设备切换，快捷键需含 ⌘ 或 ⌃"),
                       "Confirmed success is quiet in the panel presentation.")
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
        XCTAssertNil(store.failureEvent, "A successful selection does not publish a failure event.")
    }

    func testRepeatedUnavailableClicksHaveDistinctFailureEventsWithoutRefreshReplay() async throws {
        let local = device(uid: "local"), missing = device(uid: "missing")
        let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting())
        defer { store.stop() }
        store.refresh()
        await waitForState("initial catalog") { store.currentDeviceID == local.id }
        store.select(missing)
        let first = try XCTUnwrap(store.failureEvent)
        store.select(missing)
        let second = try XCTUnwrap(store.failureEvent)
        XCTAssertNotEqual(first.id, second.id, "Each explicitly rejected gesture receives its own failure event.")
        XCTAssertEqual(first.message, second.message)
        let readStarted = XCTestExpectation(description: "ordinary refresh starts")
        let read = await hardware.suspendNextSnapshot { readStarted.fulfill() }
        store.refresh()
        let started = await XCTWaiter.fulfillment(of: [readStarted], timeout: 2)
        XCTAssertEqual(started, .completed)
        await hardware.releaseSnapshot(read)
        await waitForState("ordinary refresh finishes") { !store.isRefreshing }
        XCTAssertEqual(store.failureEvent, second, "Redisplaying an unresolved reason does not replay its event.")
        let writes = await hardware.selectedUIDs()
        XCTAssertTrue(writes.isEmpty)
    }

    func testReadbackFailureAfterAcceptedSelectionClearsWhenRefreshConfirmsTarget() async {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting())
        defer { store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }
        let readStarted = XCTestExpectation(description: "selection readback starts")
        let read = await hardware.suspendNextSnapshot { readStarted.fulfill() }
        store.select(target)
        let started = await XCTWaiter.fulfillment(of: [readStarted], timeout: 2)
        XCTAssertEqual(started, .completed)
        await hardware.releaseSnapshot(read, failing: true)
        await waitForState("readback failure settles") { !store.isSwitching && store.feedbackKind == .failure }
        let underlying = store.feedback
        let failure = store.failureEvent
        XCTAssertEqual(underlying, "Injected older snapshot failure")
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Switching result not yet confirmed", "暂未确认切换结果"))
        XCTAssertEqual(failure?.message, expectedLocalized("Switching result not yet confirmed", "暂未确认切换结果"))
        XCTAssertEqual(store.currentDeviceID, target.id, "Best-effort reconciliation still publishes the actual output.")
        let refreshStarted = XCTestExpectation(description: "background reconciliation starts")
        let refreshRead = await hardware.suspendNextSnapshot { refreshStarted.fulfill() }
        store.refresh()
        let refreshed = await XCTWaiter.fulfillment(of: [refreshStarted], timeout: 2)
        XCTAssertEqual(refreshed, .completed)
        await hardware.releaseSnapshot(refreshRead)
        await waitForState("background read settles") { !store.isRefreshing }
        XCTAssertEqual(store.feedbackKind, .neutral)
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Click to switch. Shortcuts need ⌘ or ⌃", "点按设备切换，快捷键需含 ⌘ 或 ⌃"))
        XCTAssertEqual(store.failureEvent, failure, "Confirming the target must not replay or rewrite the original failure event.")
        let writes = await hardware.selectedUIDs()
        XCTAssertEqual(writes, ["target"])
    }

    func testSwitchFailureExpiresWithoutChangingOutputOrCompletedOutcome() async {
        let first = device(uid: "first"), target = device(uid: "target")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id, behavior: .failRequestedOutput)
        let routes = FakePrivateRouting()
        let store = AudioStore(hardware: hardware, routes: routes, failureFeedbackDuration: .milliseconds(100))
        defer { store.stop() }
        var outcomes: [AudioSelectionOutcome] = []
        store.onSelectionResult = { outcomes.append($0.outcome) }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }
        store.select(target)
        await waitForState("switch failure") { !store.isSwitching && store.feedbackKind == .failure }
        let failure = store.failureEvent
        XCTAssertEqual(store.feedback, "Injected HAL failure")

        await waitForState("failure expires") { store.feedbackKind == .neutral }

        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Click to switch. Shortcuts need ⌘ or ⌃", "点按设备切换，快捷键需含 ⌘ 或 ⌃"))
        XCTAssertEqual(store.currentDeviceID, first.id)
        XCTAssertEqual(store.failureEvent, failure)
        XCTAssertEqual(outcomes, [.failed("Injected HAL failure")])
        await refreshAndWait(store, hardware: hardware)
        XCTAssertEqual(store.feedbackKind, .neutral, "A later refresh must not revive an expired operation error.")
        let writes = await hardware.selectedUIDs()
        XCTAssertEqual(writes, ["target"])
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
    }

    func testMissingShortcutTargetFailureExpiresWithoutASelectionWrite() async {
        let local = device(uid: "local")
        let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting(),
                               failureFeedbackDuration: .milliseconds(100))
        defer { store.stop() }
        var outcomes: [AudioSelectionOutcome] = []
        store.onSelectionResult = { outcomes.append($0.outcome) }
        store.refresh()
        await waitForState("initial device") { store.currentDeviceID == local.id }
        let request = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))
        store.select(target: .hal(uid: "absent-full-UID"), request: request)
        let reason = store.feedback
        let failure = store.failureEvent
        XCTAssertEqual(store.feedbackKind, .failure)

        await waitForState("unresolved target failure expires") { store.feedbackKind == .neutral }

        XCTAssertEqual(outcomes, [.failed(reason)])
        XCTAssertEqual(store.failureEvent, failure)
        XCTAssertEqual(store.currentDeviceID, local.id)
        let writes = await hardware.selectedUIDs()
        XCTAssertTrue(writes.isEmpty)
    }

    func testFailureExpiryDuringCatalogFaultKeepsFaultVisibleAndDoesNotRestoreOldError() async throws {
        let local = device(uid: "local")
        let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting(),
                               failureFeedbackDuration: .milliseconds(200))
        defer { store.stop() }
        store.refresh()
        await waitForState("initial device") { store.currentDeviceID == local.id }
        store.select(device(uid: "missing"))
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Could not switch to Output missing", "无法切换到 Output missing"))
        await failCatalogRefresh(store, hardware: hardware)
        let catalogFailure = store.failureEvent

        // No public state changes when the hidden operation expires. Cross its
        // actual timer deadline, then inspect the still-current catalog fault.
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.feedbackKind, .failure)
        XCTAssertEqual(store.feedback, "Injected older snapshot failure")
        XCTAssertEqual(store.failureEvent, catalogFailure)
        XCTAssertNil(store.currentDeviceID)
        await refreshAndWait(store, hardware: hardware)

        XCTAssertEqual(store.feedbackKind, .neutral)
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Click to switch. Shortcuts need ⌘ or ⌃", "点按设备切换，快捷键需含 ⌘ 或 ⌃"))
        XCTAssertEqual(store.failureEvent, catalogFailure)
        XCTAssertEqual(store.currentDeviceID, local.id)
        let writes = await hardware.selectedUIDs()
        XCTAssertTrue(writes.isEmpty)
    }

    func testNewFailureReceivesItsOwnExpiryInsteadOfThePreviousDeadline() async throws {
        let local = device(uid: "local")
        let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting(),
                               failureFeedbackDuration: .milliseconds(800))
        defer { store.stop() }
        store.refresh()
        await waitForState("initial device") { store.currentDeviceID == local.id }
        store.select(device(uid: "first-missing"))
        let firstFailure = store.failureEvent
        try await Task.sleep(for: .milliseconds(500))
        store.select(device(uid: "second-missing"))
        let secondFailure = store.failureEvent
        XCTAssertNotEqual(firstFailure?.id, secondFailure?.id)

        // Beyond the first error's deadline, safely before the second's.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.feedbackKind, .failure)
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Could not switch to Output second-missing", "无法切换到 Output second-missing"))
        XCTAssertEqual(store.failureEvent, secondFailure)
        await waitForState("replacement failure expires") { store.feedbackKind == .neutral }
        let writes = await hardware.selectedUIDs()
        XCTAssertTrue(writes.isEmpty)
    }

    func testExpiredPreviousFailureCannotClearANewerSwitchInProgress() async throws {
        let first = device(uid: "first"), target = device(uid: "target")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id, behavior: .confirmRequestedOutput)
        let routes = FakePrivateRouting()
        let capture = SuspendedTestStep("new selection waits before writing")
        routes.onPrepareToLeave = { await capture.wait() }
        let store = AudioStore(hardware: hardware, routes: routes, failureFeedbackDuration: .milliseconds(100))
        defer { capture.release(); store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }
        store.select(device(uid: "missing"))
        store.select(target)
        let entered = await XCTWaiter.fulfillment(of: [capture.started], timeout: 2)
        XCTAssertEqual(entered, .completed)

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(store.isSwitching)
        XCTAssertEqual(store.feedbackKind, .progress)
        XCTAssertEqual(store.feedback, expectedLocalized("Switching to \(target.name)…", "正在切换到 \(target.name)…"))
        let pendingWrites = await hardware.selectedUIDs()
        XCTAssertTrue(pendingWrites.isEmpty)
        capture.release()
        await waitForState("new selection succeeds") { !store.isSwitching && store.feedbackKind == .success }
        let writes = await hardware.selectedUIDs()
        XCTAssertEqual(writes, ["target"])
    }

    func testFailureClearsOnlyWhenTheCompleteTargetIdentityIsConfirmed() async {
        let first = device(uid: "first"), target = device(uid: "target")
        let sameName = AudioDevice(id: "hal:target-suffix", name: target.name, transport: .speaker,
                                   backend: .coreAudio(uid: "target-suffix"))
        let hardware = FakeAudioHardware(devices: [first, target, sameName], current: first.id,
                                         behavior: .failRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting())
        defer { store.stop() }
        var outcomes: [AudioSelectionOutcome] = []
        store.onSelectionResult = { outcomes.append($0.outcome) }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 3 }
        store.select(target)
        await waitForState("switch failure") { !store.isSwitching && store.feedbackKind == .failure }
        let failure = store.failureEvent

        await hardware.replaceSnapshot(devices: [first, target, sameName], current: sameName.id)
        await refreshAndWait(store, hardware: hardware)
        XCTAssertEqual(store.currentDeviceID, sameName.id)
        XCTAssertEqual(store.feedbackKind, .failure, "Matching names or UID prefixes are not the failed target's identity.")
        XCTAssertEqual(store.failureEvent, failure)
        await hardware.replaceSnapshot(devices: [first, target, sameName], current: target.id)
        await refreshAndWait(store, hardware: hardware)

        XCTAssertEqual(store.feedbackKind, .neutral)
        XCTAssertEqual(store.currentDeviceID, target.id)
        XCTAssertEqual(store.failureEvent, failure)
        XCTAssertEqual(outcomes, [.failed("Injected HAL failure")], "Fresh output evidence must not rewrite the completed request's outcome.")
        let writes = await hardware.selectedUIDs()
        XCTAssertEqual(writes, ["target"])
    }

    func testAlreadySelectedConfirmationClearsOnlyItsMatchingReadbackFailure() async {
        let first = device(uid: "first"), target = device(uid: "target")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting())
        defer { store.stop() }
        var outcomes: [AudioSelectionOutcome] = []
        store.onSelectionResult = { outcomes.append($0.outcome) }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }
        let readStarted = XCTestExpectation(description: "selection readback starts")
        let read = await hardware.suspendNextSnapshot { readStarted.fulfill() }
        store.select(target)
        let started = await XCTWaiter.fulfillment(of: [readStarted], timeout: 2)
        XCTAssertEqual(started, .completed)
        await hardware.releaseSnapshot(read, failing: true)
        await waitForState("readback failure reconciles actual output") {
            !store.isSwitching && store.feedbackKind == .failure && store.currentDeviceID == target.id
        }
        let failure = store.failureEvent
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Switching result not yet confirmed", "暂未确认切换结果"))

        store.select(target)
        await waitForState("same target is confirmed again") { !store.isSwitching }

        XCTAssertEqual(store.feedbackKind, .neutral)
        XCTAssertEqual(store.failureEvent, failure)
        XCTAssertEqual(outcomes, [.failed("Injected older snapshot failure"), .alreadySelected])
        let writes = await hardware.selectedUIDs()
        XCTAssertEqual(writes, ["target"], "Read-only confirmation must not resubmit the selection.")
    }

    func testTimeoutFailureExpiryKeepsNativeOperationLockedUntilItReturns() async {
        let first = device(uid: "first"), target = device(uid: "target")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id, behavior: .confirmRequestedOutput)
        let routes = FakePrivateRouting()
        let cleanup = SuspendedTestStep("cleanup remains in flight")
        routes.onCompletedLeave = { await cleanup.wait() }
        let store = AudioStore(hardware: hardware, routes: routes, timeout: .milliseconds(50),
                               failureFeedbackDuration: .milliseconds(100))
        defer { cleanup.release(); store.stop() }
        var outcomes: [AudioSelectionOutcome] = []
        store.onSelectionResult = { outcomes.append($0.outcome) }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }
        store.select(target)
        let entered = await XCTWaiter.fulfillment(of: [cleanup.started], timeout: 2)
        XCTAssertEqual(entered, .completed)
        await waitForState("timeout produces failure") { store.feedbackKind == .failure }
        let reason = store.feedback
        let failure = store.failureEvent

        await waitForState("expired failure shows pending native work") { store.feedbackKind == .progress }
        XCTAssertTrue(store.isSwitching)
        XCTAssertEqual(store.feedback, expectedLocalized("Still waiting for switching to finish…", "仍在等待切换结束…"))
        XCTAssertEqual(store.failureEvent, failure)
        XCTAssertEqual(outcomes, [.failed(reason)])
        cleanup.release()
        await waitForState("real completion releases lock and presentation") {
            !store.isSwitching && store.feedbackKind == .neutral
        }
        XCTAssertEqual(store.currentDeviceID, target.id)
        XCTAssertEqual(outcomes, [.failed(reason)])
        let writes = await hardware.selectedUIDs()
        XCTAssertEqual(writes, ["target"])
    }

    func testStopAndShutdownPreventLateFailureExpiryPublication() async throws {
        for useStop in [true, false] {
            let local = device(uid: "local")
            let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .confirmRequestedOutput)
            let store = AudioStore(hardware: hardware, routes: FakePrivateRouting(),
                                   failureFeedbackDuration: .milliseconds(50))
            store.refresh()
            await waitForState("initial device") { store.currentDeviceID == local.id }
            store.select(device(uid: "missing"))
            let reason = store.feedback
            let failure = store.failureEvent

            if useStop { store.stop() } else { try await store.shutdown() }
            try await Task.sleep(for: .milliseconds(150))

            XCTAssertEqual(store.feedback, reason)
            XCTAssertEqual(store.feedbackKind, .failure)
            XCTAssertEqual(store.failureEvent, failure)
            XCTAssertEqual(store.currentDeviceID, local.id)
            let writes = await hardware.selectedUIDs()
            XCTAssertTrue(writes.isEmpty)
            try await store.shutdown()
        }
    }

    func testExternalOutputChangeClearsPreviousSuccessFeedback() async {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting())
        defer { store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }

        store.select(target)
        await waitForState("confirmed output") { !store.isSwitching && store.feedbackKind == .success }
        XCTAssertEqual(store.currentDeviceID, target.id)

        await hardware.replaceSnapshot(devices: [first, target], current: first.id)
        store.refresh()
        await waitForState("external output readback") { store.currentDeviceID == first.id && store.feedbackKind == .neutral }

        XCTAssertEqual(store.feedback, expectedLocalized("Click a device to switch output", "点击设备以切换输出"))
        let selections = await hardware.selectedUIDs()
        XCTAssertEqual(selections, ["target"], "Refreshing an external change must not write another route.")
    }

    func testTransientCatalogReadFailureClearsAfterSuccessfulRefresh() async {
        let local = device(uid: "local")
        let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting())
        defer { store.stop() }
        store.refresh()
        await waitForState("initial healthy catalog") { store.currentDeviceID == local.id }

        await failCatalogRefresh(store, hardware: hardware)
        XCTAssertTrue(store.devices.allSatisfy { !$0.isAvailable })
        XCTAssertEqual(store.discoveryInventory.presence(of: .hal(uid: "absent-usb")), .unconfirmed)

        store.refresh()
        await waitForState("healthy catalog recovered") { store.currentDeviceID == local.id && store.feedbackKind == .neutral }
        XCTAssertEqual(store.feedback, expectedLocalized("Click a device to switch output", "点击设备以切换输出"))
        XCTAssertTrue(store.devices.allSatisfy(\.isAvailable))
        let writes = await hardware.selectedUIDs()
        XCTAssertTrue(writes.isEmpty, "Catalog recovery itself must not change system output.")
    }

    func testPrivateDiscoveryFailureRetainsPreviousReceiverGreyUntilCompleteMissingRead() async {
        let local = device(uid: "local")
        let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .confirmRequestedOutput)
        let routes = FakePrivateRouting(routes: [receiver(selected: false)])
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { store.stop() }
        store.refresh()
        await waitForState("receiver initially found") { store.devices.count == 2 }
        XCTAssertEqual(store.discoveryInventory.presence(of: .receiver(identifier: "bedroom")), .found)

        routes.discoveryOverride = .unconfirmed
        routes.replaceRoutes([])
        store.refresh()
        await waitForState("failed private discovery preserves disabled receiver") {
            store.devices.first { $0.id == "route:bedroom" }?.isAvailable == false
        }
        XCTAssertEqual(store.discoveryInventory.presence(of: .receiver(identifier: "bedroom")), .unconfirmed)
        XCTAssertTrue(store.devices.first { $0.id == local.id }?.isAvailable == true)
        XCTAssertEqual(store.discoveryInventory.presence(of: .hal(uid: "absent-usb")), .missing)

        routes.discoveryOverride = .init(isComplete: true)
        store.refresh()
        await waitForState("complete discovery establishes receiver absence") { store.devices == [local] }
        XCTAssertEqual(store.discoveryInventory.presence(of: .receiver(identifier: "bedroom")), .missing)
        let writes = await hardware.selectedUIDs()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
    }

    func testSpeakersUSBAndConnectedBluetoothSelectThroughSamePublicHALPath() async {
        let devices = [AudioTransport.speaker, .usb, .bluetooth].map { transport in
            AudioDevice(id: "hal:\(transport.rawValue)", name: transport.rawValue, transport: transport,
                backend: .coreAudio(uid: transport.rawValue), shortcutTarget: .hal(uid: transport.rawValue))
        }
        let hardware = FakeAudioHardware(devices: devices, current: nil, behavior: .confirmRequestedOutput)
        let routes = FakePrivateRouting()
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { store.stop() }
        store.refresh()
        await waitForState("public outputs found") { store.devices.count == 3 }
        for device in devices {
            store.select(device)
            await waitForState("public output confirms \(device.name)") {
                !store.isSwitching && store.currentDeviceID == device.id
            }
        }
        let writes = await hardware.selectedUIDs()
        XCTAssertEqual(writes, ["speaker", "usb", "bluetooth"])
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
    }

    func testRepeatedCatalogReadFailuresRestorePreviousSwitchFailureAfterRecovery() async {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id, behavior: .failRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting())
        defer { store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }
        store.select(target)
        await waitForState("switch failure") { !store.isSwitching && store.feedbackKind == .failure }
        let switchFailure = store.feedback
        XCTAssertEqual(switchFailure, "Injected HAL failure")

        await failCatalogRefresh(store, hardware: hardware)
        let catalogFailureEvent = store.failureEvent
        await failCatalogRefresh(store, hardware: hardware)
        XCTAssertEqual(store.failureEvent, catalogFailureEvent, "The same continuing read failure is not a new event on every poll.")
        store.refresh()
        await waitForState("catalog recovered without losing switch failure") {
            store.currentDeviceID == first.id && store.feedback == switchFailure
        }
        XCTAssertEqual(store.feedbackKind, .failure)
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Could not switch to \(target.name)", "无法切换到 \(target.name)"))
        XCTAssertEqual(store.failureEvent, catalogFailureEvent, "Restoring an older operation reason does not replay its event.")
        let writes = await hardware.selectedUIDs()
        XCTAssertEqual(writes, ["target"], "Recovery must not retry a failed switch.")
    }

    func testCatalogRecoveryPreservesSwitchTimeoutFeedback() async {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id, behavior: .leaveOutputUnchanged)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting(), timeout: .milliseconds(10))
        defer { store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }
        store.select(target)
        await waitForState("switch timeout") { !store.isSwitching && store.feedbackKind == .failure }
        let timeoutFeedback = store.feedback

        await failCatalogRefresh(store, hardware: hardware)
        store.refresh()
        await waitForState("catalog recovered without losing timeout") {
            store.currentDeviceID == first.id && store.feedback == timeoutFeedback
        }
        XCTAssertEqual(store.feedbackKind, .failure)
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Switching result not yet confirmed", "暂未确认切换结果"))
        let writes = await hardware.selectedUIDs()
        XCTAssertEqual(writes, ["target"])
    }

    func testCatalogRecoveryPreservesUnavailableClickFeedback() async {
        let local = device(uid: "local")
        let missing = device(uid: "missing")
        let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting())
        defer { store.stop() }
        store.refresh()
        await waitForState("initial healthy catalog") { store.currentDeviceID == local.id }
        store.select(missing)
        let clickFailure = store.feedback

        await failCatalogRefresh(store, hardware: hardware)
        store.refresh()
        await waitForState("catalog recovered without losing unavailable click") {
            store.currentDeviceID == local.id && store.feedback == clickFailure
        }
        XCTAssertEqual(store.feedbackKind, .failure)
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Could not switch to \(missing.name)", "无法切换到 \(missing.name)"))
        let writes = await hardware.selectedUIDs()
        XCTAssertTrue(writes.isEmpty)
    }

    func testUnavailableClickDuringCatalogFailureSupersedesEarlierFeedback() async {
        let local = device(uid: "local")
        let missing = device(uid: "missing")
        let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting())
        defer { store.stop() }
        store.refresh()
        await waitForState("initial healthy catalog") { store.currentDeviceID == local.id }
        await failCatalogRefresh(store, hardware: hardware)
        store.select(missing)
        let clickFailure = store.feedback

        store.refresh()
        await waitForState("catalog recovered after newer unavailable click") { store.currentDeviceID == local.id }
        XCTAssertEqual(store.feedback, clickFailure)
        XCTAssertEqual(store.feedbackKind, .failure, "Recovery must not restore the neutral feedback saved before the newer action.")
        let writes = await hardware.selectedUIDs()
        XCTAssertTrue(writes.isEmpty)
    }

    func testConfirmedSuccessRestoresAfterTransientCatalogReadFailure() async {
        await verifySuccessFeedbackAfterCatalogRecovery(externalOutputChanges: false)
    }

    func testExternalOutputChangeDuringCatalogFailureClearsPreviousSuccess() async {
        await verifySuccessFeedbackAfterCatalogRecovery(externalOutputChanges: true)
    }

    private func verifySuccessFeedbackAfterCatalogRecovery(externalOutputChanges: Bool) async {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting())
        defer { store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }
        store.select(target)
        await waitForState("confirmed output") { !store.isSwitching && store.feedbackKind == .success }
        let successFeedback = store.feedback

        await failCatalogRefresh(store, hardware: hardware)
        if externalOutputChanges {
            await hardware.replaceSnapshot(devices: [first, target], current: first.id)
        }
        store.refresh()
        await waitForState("catalog recovered after a confirmed switch") {
            store.currentDeviceID == (externalOutputChanges ? first.id : target.id)
        }
        XCTAssertEqual(store.feedbackKind, externalOutputChanges ? .neutral : .success)
        XCTAssertEqual(store.feedback, externalOutputChanges ? expectedLocalized("Click a device to switch output", "点击设备以切换输出") : successFeedback)
        let writes = await hardware.selectedUIDs()
        XCTAssertEqual(writes, ["target"])
    }

    func testExternalAirPlayConnectionKeepsConfirmingHALRowUntilExactReceiverAssociationWithoutWrites() async {
        let local = device(uid: "local")
        let stream = AudioDevice(id: "hal:external-stream", name: "AirPlay", transport: .airplay,
                                 backend: .coreAudio(uid: "external-stream"))
        let unavailableReceiver = PrivateAudioRoute(identifier: "bedroom", name: "Bedroom", uid: nil,
                                                   isSelected: false, canSelect: false, transport: "airplay")
        let hardware = FakeAudioHardware(devices: [local], current: local.id, behavior: .confirmRequestedOutput)
        let routes = FakePrivateRouting(routes: [unavailableReceiver])
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { store.stop() }
        store.start()
        await waitForState("local output and disabled Bedroom before external connection") {
            store.currentDeviceID == local.id && store.devices.count == 2
        }
        XCTAssertFalse(store.devices.first { $0.id == "route:bedroom" }?.isAvailable ?? true)

        // macOS publishes its new default HAL stream before private discovery
        // supplies the exact receiver UID. No app selection initiates this path.
        await hardware.replaceSnapshot(devices: [local, stream], current: stream.id)
        await waitForState("new HAL default stays visible while receiver identity is pending") {
            store.currentDeviceID == stream.id && store.devices.count == 3
        }
        XCTAssertEqual(store.devices.map(\.id), [local.id, stream.id, "route:bedroom"])
        XCTAssertFalse(store.devices[1].isAvailable)
        XCTAssertFalse(store.devices[2].isAvailable)
        XCTAssertEqual(store.lastHardwareSnapshot?.devices, [local, stream])
        XCTAssertEqual(store.lastHardwareSnapshot?.currentDeviceID, stream.id)
        XCTAssertEqual(store.lastRouteSnapshot?.routes, [unavailableReceiver])

        let associatedReceiver = PrivateAudioRoute(identifier: "bedroom", name: "Bedroom", uid: "external-stream",
                                                  isSelected: true, canSelect: true, transport: "airplay")
        routes.replaceRoutes([associatedReceiver])
        await waitForState("delayed exact receiver identity becomes the current output") {
            store.currentDeviceID == "route:bedroom" && store.devices.count == 2 && store.catalogWarning == nil
        }

        XCTAssertEqual(store.devices.map(\.id), [local.id, "route:bedroom"])
        XCTAssertEqual(store.devices[1].backend, .privateRoute(identifier: "bedroom"))
        XCTAssertTrue(store.devices[1].isAvailable)
        XCTAssertEqual(store.lastHardwareSnapshot?.devices, [local, stream])
        XCTAssertEqual(store.lastHardwareSnapshot?.currentDeviceID, stream.id)
        XCTAssertEqual(store.lastRouteSnapshot?.routes, [associatedReceiver])
        XCTAssertFalse(store.isSwitching)
        XCTAssertFalse(store.feedback.hasPrefix(expectedLocalized("Switched to", "已切换到")), "External observation must not claim an app-initiated switch.")
        let selections = await hardware.selectedUIDs()
        XCTAssertTrue(selections.isEmpty)
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
    }

    func testDeviceRemovedFromFreshSnapshotRejectsStaleClickWithoutHardwareWrite() async {
        let first = device(uid: "first")
        let staleTarget = device(uid: "target")
        let hardware = FakeAudioHardware(devices: [first, staleTarget], current: first.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting())
        defer { store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }

        await hardware.replaceSnapshot(devices: [first], current: first.id)
        store.refresh()
        await waitForState("removed device observed") { store.devices == [first] }
        store.select(staleTarget)

        XCTAssertFalse(store.isSwitching)
        XCTAssertEqual(store.feedbackKind, .failure)
        XCTAssertEqual(store.currentDeviceID, first.id)
        let selections = await hardware.selectedUIDs()
        XCTAssertTrue(selections.isEmpty)
    }

    func testAssociatedHALCannotBypassDisabledPrivateRouteOnClick() async {
        let local = device(uid: "local")
        let transport = AudioDevice(id: "hal:aggregate-stream", name: "AirPlay", transport: .airplay,
                                    backend: .coreAudio(uid: "aggregate-stream"))
        let hardware = FakeAudioHardware(devices: [local, transport], current: local.id,
                                         behavior: .confirmRequestedOutput)
        let routes = FakePrivateRouting(routes: [
            PrivateAudioRoute(identifier: "bedroom", name: "Bedroom", uid: "aggregate-stream",
                              isSelected: false, canSelect: false, transport: "airplay"),
        ])
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { store.stop() }
        store.refresh()
        await waitForState("receiver replaces its HAL transport") { store.devices.count == 2 }
        guard let receiver = store.devices.first(where: { $0.id == "route:bedroom" }) else {
            return XCTFail("Missing stable receiver identity")
        }

        // Even an old UI reference to the previously exposed HAL row must not
        // send a write once the fresh catalog has identified its receiver.
        store.select(transport)
        store.select(receiver)

        XCTAssertFalse(store.isSwitching)
        XCTAssertEqual(store.feedbackKind, .failure)
        XCTAssertEqual(store.currentDeviceID, local.id)
        XCTAssertFalse(receiver.isAvailable)
        let hardwareSelections = await hardware.selectedUIDs()
        XCTAssertTrue(hardwareSelections.isEmpty)
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
    }

    func testLocalSwitchCapturesBeforeHALAndCleansBeforeUnlocking() async {
        let local = device(uid: "local")
        let other = device(uid: "other")
        let stream = AudioDevice(id: "hal:stream", name: "AirPlay", transport: .airplay, backend: .coreAudio(uid: "stream"))
        let events = SwitchEvents()
        let hardware = FakeAudioHardware(devices: [local, other, stream], current: stream.id,
                                         behavior: .confirmRequestedOutput, events: events)
        let routes = FakePrivateRouting(routes: [receiver(selected: true)], events: events)
        let cleanup = SuspendedTestStep("cleanup entered")
        routes.onPrepareToLeave = {
            let snapshot = try await hardware.snapshot()
            XCTAssertEqual(snapshot.currentDeviceID, stream.id, "Capture must see the still-selected system route.")
        }
        routes.onCompletedLeave = { [weak routes] in
            let snapshot = try await hardware.snapshot()
            XCTAssertEqual(snapshot.currentDeviceID, local.id, "Cleanup must observe the completed HAL change.")
            await cleanup.wait()
            routes?.replaceRoutes([self.receiver(selected: false)])
        }
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { cleanup.release(); store.stop() }
        store.refresh()
        await waitForState("initial system receiver") { store.currentDeviceID == "route:bedroom" }

        store.select(local)
        let entered = await XCTWaiter.fulfillment(of: [cleanup.started], timeout: 2)
        XCTAssertEqual(entered, .completed)
        XCTAssertTrue(store.isSwitching)
        store.select(other)
        let pendingEvents = await events.values()
        XCTAssertEqual(pendingEvents, ["prepare", "hal:local", "cleanup"])

        cleanup.release()
        await waitForState("cleanup finishes the original switch") { !store.isSwitching && store.feedbackKind == .success }
        XCTAssertEqual(store.currentDeviceID, local.id)
        let completedEvents = await events.values()
        XCTAssertEqual(completedEvents, ["prepare", "hal:local", "cleanup"], "The second click must not interleave or queue another transition.")
    }

    func testHALBluetoothAndUSBUseSystemStrategyAndConfirmReadback() async throws {
        for transport in [AudioTransport.bluetooth, .usb] {
            let local = device(uid: "local")
            let target = AudioDevice(id: "hal:accessory", name: "Accessory", transport: transport,
                                     backend: .coreAudio(uid: "accessory"))
            let events = SwitchEvents()
            let hardware = FakeAudioHardware(devices: [local, target], current: local.id,
                                             behavior: .confirmRequestedOutput, events: events)
            let routes = FakePrivateRouting(events: events)
            let store = AudioStore(hardware: hardware, routes: routes)
            store.refresh()
            await waitForState("\(transport) available through HAL") { store.devices.count == 2 }

            store.select(target)
            await waitForState("\(transport) confirmed by HAL") {
                !store.isSwitching && store.feedbackKind == .success
            }

            XCTAssertEqual(store.currentDeviceID, target.id)
            XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
            let recorded = await events.values()
            XCTAssertEqual(recorded, ["prepare", "hal:accessory", "cleanup"])
            try await store.shutdown()
        }
    }

    func testExternalHALChangeNotifiesRouteLifecycleBeforeCatalogRefresh() async throws {
        let local = device(uid: "local")
        let stream = AudioDevice(id: "hal:stream", name: "AirPlay", transport: .airplay,
                                 backend: .coreAudio(uid: "stream"))
        let events = SwitchEvents()
        let hardware = FakeAudioHardware(devices: [local, stream], current: stream.id,
                                         behavior: .confirmRequestedOutput, events: events)
        let routes = FakePrivateRouting(routes: [receiver(selected: true)], events: events)
        let store = AudioStore(hardware: hardware, routes: routes)
        store.start()
        await waitForState("system receiver initially selected") { store.currentDeviceID == "route:bedroom" }
        routes.onSystemOutputDidChange = { [weak routes, weak store] in
            XCTAssertEqual(store?.currentDeviceID, "route:bedroom",
                           "The lifecycle signal must precede catalog refresh.")
            routes?.replaceRoutes([self.receiver(selected: false)])
        }

        await hardware.replaceSnapshot(devices: [local], current: local.id)
        await waitForState("external local output appears") { store.currentDeviceID == local.id }

        XCTAssertEqual(routes.systemOutputChangeCount, 1)
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
        let selections = await hardware.selectedUIDs()
        XCTAssertTrue(selections.isEmpty, "Observing an external selection must not issue another HAL selection.")
        let recorded = await events.values()
        XCTAssertTrue(recorded.isEmpty, "The route service receives the event and owns reconciliation; Store must not initiate a leave transaction.")
        try await store.shutdown()
    }

    func testFailedHALStillRunsLeaveCleanupWithoutClaimingLocalSelection() async {
        let local = device(uid: "local")
        let stream = AudioDevice(id: "hal:stream", name: "AirPlay", transport: .airplay, backend: .coreAudio(uid: "stream"))
        let events = SwitchEvents()
        let hardware = FakeAudioHardware(devices: [local, stream], current: stream.id,
                                         behavior: .failRequestedOutput, events: events)
        let routes = FakePrivateRouting(routes: [receiver(selected: true)], events: events)
        routes.onCompletedLeave = {
            let snapshot = try await hardware.snapshot()
            XCTAssertEqual(snapshot.currentDeviceID, stream.id, "The native cleanup must receive an opportunity to inspect live state even after a HAL error.")
        }
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { store.stop() }
        store.refresh()
        await waitForState("initial system receiver") { store.currentDeviceID == "route:bedroom" }

        store.select(local)
        await waitForState("failed HAL request finishes") { !store.isSwitching && store.feedbackKind == .failure }

        let recorded = await events.values()
        XCTAssertEqual(recorded, ["prepare", "hal:local", "cleanup"])
        XCTAssertEqual(store.currentDeviceID, "route:bedroom")
        XCTAssertFalse(store.feedback.hasPrefix(expectedLocalized("Switched to", "已切换到")))
    }

    func testCaptureFailurePreventsHALWriteAndLeaveCleanup() async {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let events = SwitchEvents()
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id,
                                         behavior: .confirmRequestedOutput, events: events)
        let routes = FakePrivateRouting(events: events)
        routes.onPrepareToLeave = { throw AudioServiceError.unavailable("Injected capture failure") }
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }

        store.select(target)
        await waitForState("capture failure finishes") { !store.isSwitching && store.feedbackKind == .failure }

        let recorded = await events.values()
        XCTAssertEqual(recorded, ["prepare"])
        XCTAssertEqual(store.currentDeviceID, first.id)
    }

    func testCleanupFailurePreservesActualLocalReadbackWithoutReportingSuccess() async {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let events = SwitchEvents()
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id,
                                         behavior: .confirmRequestedOutput, events: events)
        let routes = FakePrivateRouting(events: events)
        routes.onCompletedLeave = { throw AudioServiceError.unavailable("Injected cleanup failure") }
        let store = AudioStore(hardware: hardware, routes: routes, failureFeedbackDuration: .milliseconds(500))
        var outcomes: [AudioSelectionOutcome] = []
        store.onSelectionResult = { outcomes.append($0.outcome) }
        defer { store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }

        store.select(target)
        await waitForState("cleanup failure finishes") { !store.isSwitching && store.feedbackKind == .failure }

        let recorded = await events.values()
        XCTAssertEqual(recorded, ["prepare", "hal:target", "cleanup"])
        XCTAssertEqual(store.currentDeviceID, target.id, "A cleanup error must not erase the actual system output.")
        XCTAssertEqual(store.feedback, "Injected cleanup failure")
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Switching did not finish", "切换未完成"))
        XCTAssertEqual(store.failureEvent?.message, expectedLocalized("Switching did not finish", "切换未完成"))
        XCTAssertEqual(outcomes, [.failed("Injected cleanup failure")])
        let writes = await hardware.selectedUIDs()
        XCTAssertEqual(writes, ["target"], "Presentation must not add a write or retry after cleanup fails.")
        XCTAssertFalse(store.feedback.hasPrefix(expectedLocalized("Switched to", "已切换到")))
        await refreshAndWait(store, hardware: hardware)
        XCTAssertEqual(store.feedbackKind, .failure, "Confirmed output alone does not resolve a cleanup failure.")
        XCTAssertEqual(store.presentationFeedback, expectedLocalized("Switching did not finish", "切换未完成"))
        store.select(target)
        await waitForState("same output is reconfirmed") { !store.isSwitching }
        XCTAssertEqual(store.feedbackKind, .failure, "Read-only no-op confirmation does not confirm cleanup.")
        XCTAssertEqual(outcomes, [.failed("Injected cleanup failure"), .alreadySelected])
        await waitForState("cleanup failure presentation expires") { store.feedbackKind == .neutral }
        let finalWrites = await hardware.selectedUIDs()
        XCTAssertEqual(finalWrites, ["target"])
    }

    func testTimeoutDuringLeaveCleanupKeepsSequenceLockedUntilCleanupReturns() async {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let other = device(uid: "other")
        let events = SwitchEvents()
        let hardware = FakeAudioHardware(devices: [first, target, other], current: first.id,
                                         behavior: .confirmRequestedOutput, events: events)
        let routes = FakePrivateRouting(events: events)
        let cleanup = SuspendedTestStep("cleanup entered before timeout")
        routes.onCompletedLeave = { await cleanup.wait() }
        let store = AudioStore(hardware: hardware, routes: routes, timeout: .milliseconds(100))
        defer { cleanup.release(); store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 3 }

        store.select(target)
        let entered = await XCTWaiter.fulfillment(of: [cleanup.started], timeout: 2)
        XCTAssertEqual(entered, .completed)
        await waitForState("cleanup timeout is reported") { store.feedbackKind == .failure }
        XCTAssertTrue(store.isSwitching)
        store.select(other)
        let pendingEvents = await events.values()
        XCTAssertEqual(pendingEvents, ["prepare", "hal:target", "cleanup"])

        cleanup.release()
        await waitForState("cleanup returns and the target is confirmed") {
            !store.isSwitching && store.feedbackKind == .neutral
        }
        XCTAssertFalse(store.feedback.hasPrefix(expectedLocalized("Switched to", "已切换到")))
        let completedEvents = await events.values()
        XCTAssertEqual(completedEvents, ["prepare", "hal:target", "cleanup"])
    }

    func testTimeoutDuringCapturePreventsALateHALWrite() async {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let events = SwitchEvents()
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id,
                                         behavior: .confirmRequestedOutput, events: events)
        let routes = FakePrivateRouting(events: events)
        let capture = SuspendedTestStep("capture entered before timeout")
        routes.onPrepareToLeave = { await capture.wait() }
        let store = AudioStore(hardware: hardware, routes: routes, timeout: .milliseconds(100))
        defer { capture.release(); store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }

        store.select(target)
        let entered = await XCTWaiter.fulfillment(of: [capture.started], timeout: 2)
        XCTAssertEqual(entered, .completed)
        await waitForState("capture timeout is reported") { store.feedbackKind == .failure }
        XCTAssertTrue(store.isSwitching)
        capture.release()
        await waitForState("capture returns after timeout") { !store.isSwitching }

        let recorded = await events.values()
        XCTAssertEqual(recorded, ["prepare"], "A cancelled capture must never submit the later HAL write.")
        XCTAssertEqual(store.currentDeviceID, first.id)
        XCTAssertEqual(store.feedbackKind, .failure)
    }

    func testPrivateRequestTimeoutKeepsLockAndIgnoresLateSelectionCompletion() async {
        let first = device(uid: "first")
        let other = device(uid: "other")
        let hardware = FakeAudioHardware(devices: [first, other], current: first.id, behavior: .confirmRequestedOutput)
        let routes = FakePrivateRouting(routes: [
            PrivateAudioRoute(identifier: "slow-route", name: "Slow receiver", uid: nil,
                              isSelected: false, canSelect: true, transport: "airplay"),
        ], suspendSelection: true)
        let store = AudioStore(hardware: hardware, routes: routes, timeout: .milliseconds(10))
        defer {
            store.stop()
            routes.releasePendingSelections()
        }
        store.refresh()
        await waitForState("private route discovered") { store.devices.contains(where: { $0.id == "route:slow-route" }) }
        guard let target = store.devices.first(where: { $0.id == "route:slow-route" }) else {
            return XCTFail("Missing private fixture route")
        }

        store.select(target)
        await waitForState("request phase times out") { store.feedbackKind == .failure }
        XCTAssertTrue(store.isSwitching, "Cancellation does not mean the private operation or its cleanup has returned.")
        store.select(other)
        XCTAssertEqual(routes.selectedIdentifiers, ["slow-route"])
        XCTAssertEqual(store.currentDeviceID, first.id)

        // Simulate a private framework ignoring cancellation, then returning late
        // with an apparently selected route. It must not turn the expired request
        // into a success. A later refresh may still reflect real system changes.
        let lateCompletion = XCTestExpectation(description: "late private callback returned")
        routes.selectionDidReturn = { lateCompletion.fulfill() }
        routes.releasePendingSelections(selecting: "slow-route")
        let completionResult = await XCTWaiter.fulfillment(of: [lateCompletion], timeout: 2)
        XCTAssertEqual(completionResult, .completed)
        await waitForState("late operation releases the lock") { !store.isSwitching }

        XCTAssertFalse(store.isSwitching)
        XCTAssertEqual(store.feedbackKind, .failure)
        let hardwareSelections = await hardware.selectedUIDs()
        XCTAssertTrue(hardwareSelections.isEmpty)
    }

    func testOlderRefreshFailureCannotEraseNewerConfirmedOutput() async {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id, behavior: .confirmRequestedOutput)
        let store = AudioStore(hardware: hardware, routes: FakePrivateRouting())
        defer {
            store.stop()
            Task { await hardware.releaseAllSnapshots() }
        }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }

        let oldReadStarted = XCTestExpectation(description: "older refresh is suspended")
        let oldRead = await hardware.suspendNextSnapshot { oldReadStarted.fulfill() }
        store.refresh()
        let oldReadResult = await XCTWaiter.fulfillment(of: [oldReadStarted], timeout: 2)
        XCTAssertEqual(oldReadResult, .completed)

        // The actor permits another read while the older request is suspended.
        store.select(target)
        await waitForState("newer switch readback confirms") { !store.isSwitching && store.feedbackKind == .success }
        XCTAssertEqual(store.currentDeviceID, target.id)

        // Queue one more refresh as a synchronization barrier. Its start proves
        // that the preceding old failure was fully handled. Keep this read paused
        // so it cannot repair any state incorrectly overwritten by the old error.
        let barrierStarted = XCTestExpectation(description: "old refresh failure was handled")
        let barrierRead = await hardware.suspendNextSnapshot { barrierStarted.fulfill() }
        store.refresh()
        await hardware.releaseSnapshot(oldRead, failing: true)
        let barrierResult = await XCTWaiter.fulfillment(of: [barrierStarted], timeout: 2)
        XCTAssertEqual(barrierResult, .completed)

        XCTAssertEqual(store.currentDeviceID, target.id)
        XCTAssertEqual(store.feedbackKind, .success)
        XCTAssertTrue(store.devices.allSatisfy(\.isAvailable))
        let hardwareSelections = await hardware.selectedUIDs()
        XCTAssertEqual(hardwareSelections, ["target"])

        await hardware.releaseSnapshot(barrierRead)
    }

    func testSelectedReceiverShutdownOnlyReleasesAppResourcesAndIsIdempotent() async throws {
        let local = device(uid: "local")
        let stream = AudioDevice(id: "hal:stream", name: "AirPlay", transport: .airplay,
                                 backend: .coreAudio(uid: "stream"))
        let events = SwitchEvents()
        let hardware = FakeAudioHardware(devices: [local, stream], current: stream.id,
                                         behavior: .confirmRequestedOutput, events: events)
        let routes = FakePrivateRouting(routes: [receiver(selected: true)], events: events)
        let store = AudioStore(hardware: hardware, routes: routes)
        store.start()
        await waitForState("initial system receiver") { store.currentDeviceID == "route:bedroom" }

        try await store.shutdown()
        try await store.shutdown()
        store.stop()
        store.start()
        store.refresh()
        store.select(local)

        XCTAssertEqual(store.currentDeviceID, "route:bedroom")
        XCTAssertEqual(routes.beginShutdownCount, 1)
        XCTAssertEqual(routes.shutdownCount, 1)
        XCTAssertEqual(routes.startCount, 1)
        XCTAssertNil(routes.onChange)
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
        let observation = await hardware.observationState()
        XCTAssertFalse(observation.isObserving)
        XCTAssertEqual(observation.stopCount, 1)
        let snapshot = try await hardware.snapshot()
        XCTAssertEqual(snapshot.currentDeviceID, stream.id, "Quit must preserve the selected Bedroom output.")
        let selections = await hardware.selectedUIDs()
        XCTAssertTrue(selections.isEmpty)
        let recorded = await events.values()
        XCTAssertEqual(recorded, ["shutdown", "hardware-stop"], "Quit must not capture, select, disconnect, or roll back a receiver.")
    }

    func testInternalShutdownErrorStillStopsObserversWithoutRestartOrOutputWrite() async {
        let local = device(uid: "local")
        let stream = AudioDevice(id: "hal:stream", name: "AirPlay", transport: .airplay,
                                 backend: .coreAudio(uid: "stream"))
        let hardware = FakeAudioHardware(devices: [local, stream], current: stream.id,
                                         behavior: .confirmRequestedOutput)
        let routes = FakePrivateRouting(routes: [receiver(selected: true)])
        routes.onShutdown = { throw AudioServiceError.unavailable("Injected internal release failure") }
        let store = AudioStore(hardware: hardware, routes: routes)
        store.start()
        await waitForState("initial system receiver") { store.currentDeviceID == "route:bedroom" }

        for _ in 0..<2 {
            do {
                try await store.shutdown()
                XCTFail("A real resource error must remain available for termination diagnostics.")
            } catch {
                XCTAssertEqual(error.localizedDescription, "Injected internal release failure")
            }
        }
        store.start()
        store.select(local)
        XCTAssertEqual(routes.beginShutdownCount, 1)
        XCTAssertEqual(routes.shutdownCount, 1)
        XCTAssertEqual(routes.startCount, 1, "A resource error must not resurrect discovery during termination.")
        XCTAssertNil(routes.onChange)
        let observation = await hardware.observationState()
        XCTAssertFalse(observation.isObserving)
        XCTAssertEqual(observation.stopCount, 1)
        let selections = await hardware.selectedUIDs()
        XCTAssertTrue(selections.isEmpty)
        XCTAssertFalse(store.isSwitching)
        XCTAssertEqual(store.currentDeviceID, "route:bedroom")
    }

    func testShutdownWaitsForInFlightLeaveCleanupBeforeReleasingRoutesAndObservers() async throws {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let events = SwitchEvents()
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id,
                                         behavior: .confirmRequestedOutput, events: events)
        let routes = FakePrivateRouting(events: events)
        let cleanup = SuspendedTestStep("leave cleanup entered before quit")
        routes.onCompletedLeave = {
            await cleanup.wait()
            await events.record("cleanup-return")
        }
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { cleanup.release(); store.stop() }
        store.start()
        await waitForState("initial devices") { store.devices.count == 2 }
        store.select(target)
        let entered = await XCTWaiter.fulfillment(of: [cleanup.started], timeout: 2)
        XCTAssertEqual(entered, .completed)

        let shutdownStarted = XCTestExpectation(description: "shutdown requested during cleanup")
        let shutdown = Task {
            shutdownStarted.fulfill()
            try await store.shutdown()
        }
        let requested = await XCTWaiter.fulfillment(of: [shutdownStarted], timeout: 2)
        XCTAssertEqual(requested, .completed)
        XCTAssertTrue(store.isSwitching)
        XCTAssertEqual(routes.shutdownCount, 0)
        let pendingObservation = await hardware.observationState()
        XCTAssertTrue(pendingObservation.isObserving)
        XCTAssertEqual(pendingObservation.stopCount, 0)

        cleanup.release()
        try await shutdown.value
        let recorded = await events.values()
        XCTAssertEqual(recorded, ["prepare", "hal:target", "cleanup", "cleanup-return", "shutdown", "hardware-stop"])
        XCTAssertFalse(store.isSwitching)
        XCTAssertNotEqual(store.feedbackKind, .success, "An interrupted request must not report success while quitting.")
    }

    func testShutdownCancelsCaptureBeforeItCanSubmitALateHALWrite() async throws {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let events = SwitchEvents()
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id,
                                         behavior: .confirmRequestedOutput, events: events)
        let routes = FakePrivateRouting(events: events)
        let capture = SuspendedTestStep("capture entered before quit")
        routes.onPrepareToLeave = { await capture.wait() }
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { capture.release(); store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }
        store.select(target)
        let entered = await XCTWaiter.fulfillment(of: [capture.started], timeout: 2)
        XCTAssertEqual(entered, .completed)

        let shutdownStarted = XCTestExpectation(description: "shutdown requested during capture")
        let shutdown = Task {
            shutdownStarted.fulfill()
            try await store.shutdown()
        }
        let requested = await XCTWaiter.fulfillment(of: [shutdownStarted], timeout: 2)
        XCTAssertEqual(requested, .completed)
        XCTAssertEqual(routes.shutdownCount, 0)

        capture.release()
        try await shutdown.value
        let recorded = await events.values()
        XCTAssertEqual(recorded, ["prepare", "shutdown", "hardware-stop"])
        let selections = await hardware.selectedUIDs()
        XCTAssertTrue(selections.isEmpty)
    }

    func testShutdownSuppressesSelectionQueuedBeforeItsTaskStarts() async throws {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let events = SwitchEvents()
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id,
                                         behavior: .confirmRequestedOutput, events: events)
        let routes = FakePrivateRouting(events: events)
        let store = AudioStore(hardware: hardware, routes: routes)
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }

        store.select(target)
        // No suspension between select and shutdown: the switch Task is queued,
        // but no native preparation or HAL request has been submitted yet.
        try await store.shutdown()

        let recorded = await events.values()
        XCTAssertEqual(recorded, ["shutdown", "hardware-stop"])
        XCTAssertFalse(store.isSwitching)
        XCTAssertEqual(routes.beginShutdownCount, 1)
    }

    func testShutdownSignalPreventsHALRequestWaitingBeforeCommit() async throws {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let events = SwitchEvents()
        let beforeWrite = SuspendedTestStep("HAL request waiting before write")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id,
                                         behavior: .confirmRequestedOutput, events: events,
                                         beforeSelection: { await beforeWrite.wait() })
        let routes = FakePrivateRouting(events: events)
        let shutdownSignalled = XCTestExpectation(description: "shutdown visible before cancelling HAL")
        routes.onBeginShutdown = { shutdownSignalled.fulfill() }
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { beforeWrite.release(); store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }
        store.select(target)
        let entered = await XCTWaiter.fulfillment(of: [beforeWrite.started], timeout: 2)
        XCTAssertEqual(entered, .completed)

        let shutdown = Task { try await store.shutdown() }
        let signalled = await XCTWaiter.fulfillment(of: [shutdownSignalled], timeout: 2)
        XCTAssertEqual(signalled, .completed)
        beforeWrite.release()
        try await shutdown.value

        let selections = await hardware.selectedUIDs()
        XCTAssertTrue(selections.isEmpty)
        let recorded = await events.values()
        XCTAssertEqual(recorded, ["prepare", "shutdown", "hardware-stop"])
    }

    func testShutdownDuringSubmittedHALDoesNotRunLeaveCleanup() async throws {
        try await verifyShutdownDuringSubmittedHAL(failing: false)
    }

    func testShutdownDuringFailingHALDoesNotRunLeaveCleanup() async throws {
        try await verifyShutdownDuringSubmittedHAL(failing: true)
    }

    private func verifyShutdownDuringSubmittedHAL(failing: Bool) async throws {
        let first = device(uid: "first")
        let target = device(uid: "target")
        let events = SwitchEvents()
        let afterWrite = SuspendedTestStep("HAL write submitted before quit")
        let hardware = FakeAudioHardware(devices: [first, target], current: first.id,
                                         behavior: .confirmRequestedOutput, events: events,
                                         afterSelection: {
                                             await afterWrite.wait()
                                             if failing { throw AudioServiceError.unavailable("Late HAL failure") }
                                         })
        let routes = FakePrivateRouting(events: events)
        let shutdownSignalled = XCTestExpectation(description: "shutdown signalled during HAL")
        routes.onBeginShutdown = { shutdownSignalled.fulfill() }
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { afterWrite.release(); store.stop() }
        store.refresh()
        await waitForState("initial devices") { store.devices.count == 2 }
        store.select(target)
        let entered = await XCTWaiter.fulfillment(of: [afterWrite.started], timeout: 2)
        XCTAssertEqual(entered, .completed)

        let shutdown = Task { try await store.shutdown() }
        let signalled = await XCTWaiter.fulfillment(of: [shutdownSignalled], timeout: 2)
        XCTAssertEqual(signalled, .completed)
        afterWrite.release()
        try await shutdown.value

        let recorded = await events.values()
        XCTAssertEqual(recorded, ["prepare", "hal:target", "shutdown", "hardware-stop"],
                       "Shutdown must not add cleanup or rollback after a submitted HAL call returns.")
        let selections = await hardware.selectedUIDs()
        XCTAssertEqual(selections, ["target"])
        XCTAssertFalse(store.isSwitching)
        XCTAssertNotEqual(store.feedbackKind, .success)
    }

    func testConcurrentShutdownWaitsForOneSubmittedPrivateRequestAndOneRelease() async throws {
        let local = device(uid: "local")
        let events = SwitchEvents()
        let hardware = FakeAudioHardware(devices: [local], current: local.id,
                                         behavior: .confirmRequestedOutput, events: events)
        let routes = FakePrivateRouting(routes: [receiver(selected: false)], suspendSelection: true, events: events)
        let selectionStarted = XCTestExpectation(description: "private request submitted")
        routes.selectionDidStart = { selectionStarted.fulfill() }
        let shutdownSignalled = XCTestExpectation(description: "private shutdown signal")
        routes.onBeginShutdown = { shutdownSignalled.fulfill() }
        let store = AudioStore(hardware: hardware, routes: routes)
        defer { routes.releasePendingSelections(); store.stop() }
        store.refresh()
        await waitForState("receiver available") { store.devices.count == 2 }
        guard let target = store.devices.first(where: { $0.id == "route:bedroom" }) else {
            return XCTFail("Missing receiver")
        }
        store.select(target)
        let submitted = await XCTWaiter.fulfillment(of: [selectionStarted], timeout: 2)
        XCTAssertEqual(submitted, .completed)

        let firstShutdown = Task { try await store.shutdown() }
        let signalled = await XCTWaiter.fulfillment(of: [shutdownSignalled], timeout: 2)
        XCTAssertEqual(signalled, .completed)
        let secondShutdown = Task { try await store.shutdown() }
        XCTAssertEqual(routes.shutdownCount, 0, "References must outlive the already submitted native call.")
        XCTAssertEqual(routes.beginShutdownCount, 1)
        XCTAssertTrue(routes.isShuttingDown)
        routes.releasePendingSelections(selecting: "bedroom")
        try await firstShutdown.value
        try await secondShutdown.value

        let recorded = await events.values()
        XCTAssertEqual(recorded, ["private:bedroom", "shutdown", "hardware-stop"])
        XCTAssertEqual(routes.shutdownCount, 1)
        XCTAssertEqual(routes.selectedIdentifiers, ["bedroom"])
        XCTAssertNotEqual(store.feedbackKind, .success)
        let selections = await hardware.selectedUIDs()
        XCTAssertTrue(selections.isEmpty)
    }

    func testShutdownClosesAdmissionWithoutBlockingAndDrainsRealSubmission() async {
        let signal = AudioShutdownSignal()
        let events = SynchronousTestEvents()
        let submissionStarted = XCTestExpectation(description: "write registered")
        let submissionFinished = XCTestExpectation(description: "write returned")
        let releaseSubmission = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertTrue(signal.performIfRunning {
                events.record("write")
                submissionStarted.fulfill()
                XCTAssertEqual(releaseSubmission.wait(timeout: .now() + 3), .success)
                events.record("write-return")
            })
            submissionFinished.fulfill()
        }
        let entered = await XCTWaiter.fulfillment(of: [submissionStarted], timeout: 2)
        XCTAssertEqual(entered, .completed)
        // These are MainActor calls while the real operation is blocked. Neither
        // checking nor closing may wait on its remote duration.
        signal.begin()
        events.record("shutdown")
        XCTAssertTrue(signal.isShuttingDown)
        XCTAssertThrowsError(try signal.checkRunning())
        XCTAssertFalse(signal.performIfRunning { events.record("late-write") })
        let draining = Task {
            await signal.drainSubmissions()
            events.record("drained")
        }
        await Task.yield()
        XCTAssertEqual(events.values(), ["write", "shutdown"])
        releaseSubmission.signal()
        let finished = await XCTWaiter.fulfillment(of: [submissionFinished], timeout: 2)
        XCTAssertEqual(finished, .completed)
        await draining.value
        XCTAssertEqual(events.values(), ["write", "shutdown", "write-return", "drained"])
        signal.begin()
        XCTAssertFalse(signal.performIfRunning { events.record("reopened-write") })
    }

    private func device(uid: String) -> AudioDevice {
        AudioDevice(id: "hal:\(uid)", name: "Output \(uid)", transport: .speaker, backend: .coreAudio(uid: uid))
    }

    private func receiver(selected: Bool) -> PrivateAudioRoute {
        PrivateAudioRoute(identifier: "bedroom", name: "Bedroom", uid: selected ? "stream" : nil,
                          isSelected: selected, canSelect: true, transport: "airplay")
    }

    private func failCatalogRefresh(_ store: AudioStore, hardware: FakeAudioHardware) async {
        let readStarted = XCTestExpectation(description: "injected catalog read starts")
        let failingRead = await hardware.suspendNextSnapshot { readStarted.fulfill() }
        store.refresh()
        let started = await XCTWaiter.fulfillment(of: [readStarted], timeout: 2)
        XCTAssertEqual(started, .completed)
        await hardware.releaseSnapshot(failingRead, failing: true)
        await waitForState("catalog failure applied") {
            !store.isRefreshing && store.currentDeviceID == nil && store.feedbackKind == .failure
        }
    }

    private func refreshAndWait(_ store: AudioStore, hardware: FakeAudioHardware) async {
        let readStarted = XCTestExpectation(description: "fresh catalog read starts")
        let read = await hardware.suspendNextSnapshot { readStarted.fulfill() }
        store.refresh()
        let started = await XCTWaiter.fulfillment(of: [readStarted], timeout: 2)
        XCTAssertEqual(started, .completed)
        await hardware.releaseSnapshot(read)
        await waitForState("fresh catalog read finishes") { !store.isRefreshing }
    }

    /// Observation wakes the expectation on actual state changes, rather than
    /// depending on sleeps that race the production refresh/switch tasks.
    private func waitForState(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: @escaping @MainActor () -> Bool
    ) async {
        let expectation = XCTestExpectation(description: description)
        let observation = StoreStateExpectation(expectation: expectation, predicate: predicate)
        observation.observe()
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 2)
        observation.cancel()
        XCTAssertEqual(result, .completed, description, file: file, line: line)
    }
}

@MainActor
private final class StoreStateExpectation {
    private let expectation: XCTestExpectation
    private let predicate: @MainActor () -> Bool
    private var finished = false

    init(expectation: XCTestExpectation, predicate: @escaping @MainActor () -> Bool) {
        self.expectation = expectation
        self.predicate = predicate
    }

    func observe() {
        guard !finished else { return }
        let matches = withObservationTracking {
            predicate()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        if matches {
            finished = true
            expectation.fulfill()
        }
    }

    func cancel() { finished = true }
}

private actor FakeAudioHardware: AudioHardwareProviding {
    enum SelectionBehavior: Sendable {
        case leaveOutputUnchanged
        case confirmRequestedOutput
        case failRequestedOutput
    }

    private var value: CoreAudioSnapshot
    private let behavior: SelectionBehavior
    private let events: SwitchEvents?
    private let beforeSelection: (@Sendable () async throws -> Void)?
    private let afterSelection: (@Sendable () async throws -> Void)?
    private nonisolated let shutdownSignal = AudioShutdownSignal()
    private var writes: [String] = []
    private var changed: (@Sendable () -> Void)?
    private var observationStopCount = 0
    private var plannedSnapshots: [(id: UUID, started: @Sendable () -> Void)] = []
    private var pendingSnapshots: [UUID: CheckedContinuation<CoreAudioSnapshot, any Error>] = [:]

    init(devices: [AudioDevice], current: String?, behavior: SelectionBehavior, events: SwitchEvents? = nil,
         beforeSelection: (@Sendable () async throws -> Void)? = nil,
         afterSelection: (@Sendable () async throws -> Void)? = nil) {
        value = CoreAudioSnapshot(devices: devices, currentDeviceID: current, systemSoundDeviceID: current, warnings: [],
            discovery: Self.discovery(devices), isOutputInventoryComplete: true)
        self.behavior = behavior
        self.events = events
        self.beforeSelection = beforeSelection
        self.afterSelection = afterSelection
    }

    func snapshot() async throws -> CoreAudioSnapshot {
        guard !plannedSnapshots.isEmpty else { return value }
        let plan = plannedSnapshots.removeFirst()
        return try await withCheckedThrowingContinuation { continuation in
            pendingSnapshots[plan.id] = continuation
            plan.started()
        }
    }

    func select(uid: String) async throws {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        try await beforeSelection?()
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        writes.append(uid)
        await events?.record("hal:\(uid)")
        if behavior == .failRequestedOutput { throw AudioServiceError.unavailable("Injected HAL failure") }
        guard behavior == .confirmRequestedOutput else { return }
        guard let target = value.devices.first(where: { $0.backend == .coreAudio(uid: uid) }) else {
            throw AudioServiceError.targetMissing
        }
        value = CoreAudioSnapshot(devices: value.devices, currentDeviceID: target.id,
                                  systemSoundDeviceID: value.systemSoundDeviceID, warnings: [],
                                  discovery: Self.discovery(value.devices), isOutputInventoryComplete: true)
        try await afterSelection?()
    }

    nonisolated func beginShutdown() { shutdownSignal.begin() }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        self.changed = changed
    }
    func stopObserving() async {
        changed = nil
        observationStopCount += 1
        await events?.record("hardware-stop")
    }
    func observationState() -> (isObserving: Bool, stopCount: Int) {
        (changed != nil, observationStopCount)
    }
    func selectedUIDs() -> [String] { writes }

    func suspendNextSnapshot(started: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        plannedSnapshots.append((id, started))
        return id
    }

    func releaseSnapshot(_ id: UUID, failing: Bool = false) {
        guard let continuation = pendingSnapshots.removeValue(forKey: id) else { return }
        if failing {
            continuation.resume(throwing: AudioServiceError.unavailable("Injected older snapshot failure"))
        } else {
            continuation.resume(returning: value)
        }
    }

    func releaseAllSnapshots() {
        plannedSnapshots.removeAll()
        let continuations = pendingSnapshots.values
        pendingSnapshots.removeAll()
        continuations.forEach { $0.resume(returning: value) }
    }

    func replaceSnapshot(devices: [AudioDevice], current: String?) {
        value = CoreAudioSnapshot(devices: devices, currentDeviceID: current,
                                  systemSoundDeviceID: value.systemSoundDeviceID, warnings: [],
                                  discovery: Self.discovery(devices), isOutputInventoryComplete: true)
        changed?()
    }
    private static func discovery(_ devices: [AudioDevice]) -> AudioDiscoverySourceInventory {
        .init(observedIdentifiers: Set(devices.compactMap {
            guard case let .coreAudio(uid) = $0.backend else { return nil }
            return uid
        }), isComplete: true)
    }

}

@MainActor
private final class FakePrivateRouting: PrivateRouting {
    var discoveryOverride: AudioDiscoverySourceInventory?
    var onChange: (() -> Void)?
    var selectionDidReturn: (() -> Void)?
    var selectionDidStart: (() -> Void)?
    var onBeginShutdown: (() -> Void)?
    var onSystemOutputDidChange: (() -> Void)?
    var onPrepareToLeave: (@MainActor () async throws -> Void)?
    var onCompletedLeave: (@MainActor () async throws -> Void)?
    var onShutdown: (@MainActor () async throws -> Void)?
    private(set) var startCount = 0
    private(set) var shutdownCount = 0
    private(set) var beginShutdownCount = 0
    private(set) var systemOutputChangeCount = 0
    private(set) var isShuttingDown = false
    private(set) var selectedIdentifiers: [String] = []
    private var routes: [PrivateAudioRoute]
    private let suspendSelection: Bool
    private let events: SwitchEvents?
    private var pending: [CheckedContinuation<Void, Never>] = []

    init(routes: [PrivateAudioRoute] = [], suspendSelection: Bool = false, events: SwitchEvents? = nil) {
        self.routes = routes
        self.suspendSelection = suspendSelection
        self.events = events
    }

    func start() { startCount += 1 }
    func stop() {}
    func systemOutputDidChange() {
        systemOutputChangeCount += 1
        onSystemOutputDidChange?()
    }
    func beginShutdown() {
        beginShutdownCount += 1
        isShuttingDown = true
        onBeginShutdown?()
    }
    func shutdown() async throws {
        shutdownCount += 1
        await events?.record("shutdown")
        try await onShutdown?()
    }
    func snapshot() -> PrivateRouteSnapshot {
        PrivateRouteSnapshot(routes: routes, warning: nil, diagnostics: "unit-test fixture",
            discovery: discoveryOverride ?? .init(observedIdentifiers: Set(routes.map(\.identifier)), isComplete: true))
    }

    func prepareToLeave() async throws {
        await events?.record("prepare")
        try await onPrepareToLeave?()
    }

    func completedLeave() async throws {
        await events?.record("cleanup")
        try await onCompletedLeave?()
    }

    func replaceRoutes(_ routes: [PrivateAudioRoute]) {
        self.routes = routes
        onChange?()
    }

    func select(identifier: String) async throws {
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
        selectedIdentifiers.append(identifier)
        await events?.record("private:\(identifier)")
        selectionDidStart?()
        if suspendSelection {
            await withCheckedContinuation { pending.append($0) }
        }
        selectionDidReturn?()
    }

    func releasePendingSelections(selecting identifier: String? = nil) {
        if let identifier {
            routes = routes.map {
                PrivateAudioRoute(identifier: $0.identifier, name: $0.name, uid: $0.uid,
                                  isSelected: $0.identifier == identifier, canSelect: $0.canSelect, transport: $0.transport)
            }
        }
        let continuations = pending
        pending.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
final class PrivateRouteServiceCleanupTests: XCTestCase {
    func testLateSuccessfulCallbackFinishesFailedTransactionOnceAndPublishesRecovery() async throws {
        let signal = AudioShutdownSignal()
        let firstAttempt = XCTestExpectation(description: "failed transaction is waiting for callback")
        let recovered = XCTestExpectation(description: "late cleanup publishes usable receiver")
        let worker = FailedSelectionWorker(signal: signal, outcome: .pending) { attempt in
            if attempt == 1 { firstAttempt.fulfill() }
        }
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal, cleanupRetryDelay: .milliseconds(10))
        service.onChange = {
            if service.snapshot().routes.first?.canSelect == true { recovered.fulfill() }
        }

        do {
            try await service.select(identifier: "bedroom")
            XCTFail("The original request failed; deferred cleanup must not turn it into a successful selection.")
        } catch {
            XCTAssertEqual((error as NSError).code, 10)
        }
        let waiting = await XCTWaiter.fulfillment(of: [firstAttempt], timeout: 2)
        XCTAssertEqual(waiting, .completed)
        await worker.setOutcome(.complete)
        let recovery = await XCTWaiter.fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(recovery, .completed)

        let state = await worker.state()
        XCTAssertEqual(state.submissions, 1)
        XCTAssertGreaterThanOrEqual(state.attempts, 2)
        XCTAssertEqual(state.cleanupWrites, 1, "Late reconciliation must not create another Add or repeat a successful Remove.")
        XCTAssertFalse(service.snapshot().routes.first?.isSelected ?? true)
        try await service.shutdown()
    }

    func testTerminalFailureStopsCleanupRetriesAndKeepsUnavailableSnapshot() async throws {
        let signal = AudioShutdownSignal()
        let firstAttempt = XCTestExpectation(description: "terminal cleanup result returned")
        let noSecondAttempt = XCTestExpectation(description: "terminal cleanup must not repeat")
        noSecondAttempt.isInverted = true
        let worker = FailedSelectionWorker(signal: signal, outcome: .terminal) { attempt in
            (attempt == 1 ? firstAttempt : noSecondAttempt).fulfill()
        }
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal, cleanupRetryDelay: .milliseconds(10))
        do { try await service.select(identifier: "bedroom") } catch { }
        let first = await XCTWaiter.fulfillment(of: [firstAttempt], timeout: 2)
        XCTAssertEqual(first, .completed)
        let quiet = await XCTWaiter.fulfillment(of: [noSecondAttempt], timeout: 0.08)
        XCTAssertEqual(quiet, .completed)
        let state = await worker.state()
        XCTAssertEqual(state.attempts, 1)
        XCTAssertEqual(state.cleanupWrites, 0)
        XCTAssertFalse(service.snapshot().routes.first?.canSelect ?? true)
        XCTAssertEqual(service.snapshot().diagnostics, "terminal")
        try await service.shutdown()
    }

    func testShutdownCancelsPendingCleanupWithoutAnotherAttemptOrPublication() async throws {
        let signal = AudioShutdownSignal()
        let firstAttempt = XCTestExpectation(description: "cleanup attempt before quit")
        let worker = FailedSelectionWorker(signal: signal, outcome: .pending) { attempt in
            if attempt == 1 { firstAttempt.fulfill() }
        }
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal, cleanupRetryDelay: .milliseconds(40))
        var publications = 0
        service.onChange = { publications += 1 }
        do { try await service.select(identifier: "bedroom") } catch { }
        let waiting = await XCTWaiter.fulfillment(of: [firstAttempt], timeout: 2)
        XCTAssertEqual(waiting, .completed)
        try await service.shutdown()
        let stoppedPublications = publications
        await worker.setOutcome(.complete)
        try await Task.sleep(for: .milliseconds(100))

        let state = await worker.state()
        XCTAssertEqual(state.attempts, 1)
        XCTAssertEqual(state.cleanupWrites, 0)
        XCTAssertEqual(state.stops, 1)
        XCTAssertEqual(publications, stoppedPublications)
    }

    func testSecondFailedRequestUsesOneCleanupTaskWithoutLosingItsTransaction() async throws {
        let signal = AudioShutdownSignal()
        let firstAttempt = XCTestExpectation(description: "one cleanup attempt suspended")
        let unexpectedConcurrentAttempt = XCTestExpectation(description: "duplicate cleanup must not start")
        unexpectedConcurrentAttempt.isInverted = true
        let worker = FailedSelectionWorker(signal: signal, outcome: .pending, suspendFirstAttempt: true) { attempt in
            (attempt == 1 ? firstAttempt : unexpectedConcurrentAttempt).fulfill()
        }
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal, cleanupRetryDelay: .milliseconds(10))
        do { try await service.select(identifier: "bedroom") } catch { }
        let started = await XCTWaiter.fulfillment(of: [firstAttempt], timeout: 2)
        XCTAssertEqual(started, .completed)
        do { try await service.select(identifier: "bedroom") } catch { }
        let single = await XCTWaiter.fulfillment(of: [unexpectedConcurrentAttempt], timeout: 0.08)
        XCTAssertEqual(single, .completed)

        // Quit before releasing the simulated callback: the existing task must
        // neither write nor publish when it eventually resumes.
        service.beginShutdown()
        await worker.releaseFirstAttempt(outcome: .complete)
        try await service.shutdown()
        let state = await worker.state()
        XCTAssertEqual(state.submissions, 2)
        XCTAssertEqual(state.attempts, 1)
        XCTAssertEqual(state.cleanupWrites, 0)
    }

    func testRepeatedPendingCleanupDoesNotRepublishUnchangedState() async throws {
        let signal = AudioShutdownSignal()
        let thirdAttempt = XCTestExpectation(description: "callback is still pending on third attempt")
        let worker = FailedSelectionWorker(signal: signal, outcome: .pending) { attempt in
            if attempt == 3 { thirdAttempt.fulfill() }
        }
        let service = PrivateRouteService(worker: worker, shutdownSignal: signal, cleanupRetryDelay: .milliseconds(10))
        var publications = 0
        service.onChange = { publications += 1 }
        do { try await service.select(identifier: "bedroom") } catch { }
        let waited = await XCTWaiter.fulfillment(of: [thirdAttempt], timeout: 2)
        XCTAssertEqual(waited, .completed)
        XCTAssertEqual(publications, 1)
        try await service.shutdown()
        let state = await worker.state()
        XCTAssertEqual(state.cleanupWrites, 0)
    }
}

/// Readback stays on the original output. Only submission is injected; the
/// production service owns its deadline, uncertainty error and cleanup path.
private actor SelectionPresentationWorker: PrivateRouteWorking {
    private let route: PrivateAudioRoute
    private let rejection: (any Error)?
    private var requests: [String] = []
    private var accepted = 0

    init(route: PrivateAudioRoute, rejection: (any Error)? = nil) {
        self.route = route
        self.rejection = rejection
    }

    func read() -> PrivateRouteSnapshot {
        PrivateRouteSnapshot(routes: [route], warning: nil, diagnostics: "selection presentation fixture",
            discovery: .init(observedIdentifiers: [route.identifier], isComplete: true))
    }
    func submit(identifier: String) throws {
        requests.append(identifier)
        if let rejection { throw rejection }
        accepted += 1
    }
    func prepareToLeave() {}
    func completedLeave() {}
    func finishFailedSelection() {}
    func stop() {}
    func trace() -> (requests: [String], accepted: Int) { (requests, accepted) }
}

private actor FailedSelectionWorker: PrivateRouteWorking {
    enum Outcome: String, Sendable { case pending, complete, terminal }
    private let signal: AudioShutdownSignal
    private let onAttempt: @Sendable (Int) -> Void
    private let suspendFirstAttempt: Bool
    private var suspended: CheckedContinuation<Void, Never>?
    private var outcome: Outcome
    private var submissions = 0
    private var attempts = 0
    private var cleanupWrites = 0
    private var stops = 0

    init(signal: AudioShutdownSignal, outcome: Outcome, suspendFirstAttempt: Bool = false,
         onAttempt: @escaping @Sendable (Int) -> Void) {
        self.signal = signal
        self.outcome = outcome
        self.suspendFirstAttempt = suspendFirstAttempt
        self.onAttempt = onAttempt
    }

    func read() -> PrivateRouteSnapshot {
        PrivateRouteSnapshot(routes: [PrivateAudioRoute(identifier: "bedroom", name: "Bedroom", uid: nil,
                                                        isSelected: false, canSelect: outcome == .complete,
                                                        transport: "airplay")], warning: nil, diagnostics: outcome.rawValue,
            discovery: .init(observedIdentifiers: ["bedroom"]))
    }
    func submit(identifier: String) throws {
        submissions += 1
        throw failure(code: 10)
    }
    func prepareToLeave() {}
    func completedLeave() {}
    func finishFailedSelection() async throws {
        try Task.checkCancellation()
        try signal.checkRunning()
        attempts += 1
        onAttempt(attempts)
        if suspendFirstAttempt, attempts == 1 {
            await withCheckedContinuation { suspended = $0 }
        }
        try Task.checkCancellation()
        try signal.checkRunning()
        switch outcome {
        case .pending: throw failure(code: 24)
        case .terminal: throw failure(code: 25)
        case .complete:
            guard signal.performIfRunning({ cleanupWrites += 1 }) else { throw CancellationError() }
        }
    }
    func stop() { stops += 1 }
    func setOutcome(_ value: Outcome) { outcome = value }
    func releaseFirstAttempt(outcome: Outcome) {
        self.outcome = outcome
        let pending = suspended
        suspended = nil
        pending?.resume()
    }
    func state() -> (submissions: Int, attempts: Int, cleanupWrites: Int, stops: Int) {
        (submissions, attempts, cleanupWrites, stops)
    }
    private func failure(code: Int) -> NSError {
        NSError(domain: "dev.dengziyi.ToneHop.RetainedSystemAudio", code: code,
                userInfo: [NSLocalizedDescriptionKey: "Injected failed selection \(code)"])
    }
}

private actor SwitchEvents {
    private var entries: [String] = []
    func record(_ event: String) { entries.append(event) }
    func values() -> [String] { entries }
}

private final class SynchronousTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ event: String) { lock.withLock { entries.append(event) } }
    func values() -> [String] { lock.withLock { entries } }
}

@MainActor
private final class SuspendedTestStep {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ description: String) { started = XCTestExpectation(description: description) }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
