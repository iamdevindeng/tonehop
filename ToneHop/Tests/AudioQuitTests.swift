import AppKit
import CoreAudio
import XCTest
@testable import ToneHop

@MainActor
final class AudioQuitTests: XCTestCase {
    func testCancelQuitKeepsServicesRunningAndAllowsNextSelection() async throws {
        let routes = QuitTestRoutes()
        let hardware = QuitTestHardware()
        let store = AudioStore(hardware: hardware, routes: routes)
        store.start()
        await waitUntil { !store.devices.isEmpty }
        let plan = try await store.prepareToQuit()
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertTrue(store.isPreparingToQuit)
        store.select(try XCTUnwrap(store.devices.first))
        await Task.yield()
        let before = await hardware.writes
        XCTAssertTrue(before.isEmpty)
        XCTAssertEqual(routes.shutdowns, 0)
        XCTAssertEqual(routes.leaves, 0)
        store.cancelQuit()
        XCTAssertFalse(store.isPreparingToQuit)
        store.select(try XCTUnwrap(store.devices.first))
        await waitUntil { !store.isSwitching }
        let after = await hardware.writes
        XCTAssertEqual(after, ["speaker"])
        XCTAssertEqual(routes.shutdowns, 0)
        try await store.shutdown()
    }

    func testConfirmedQuitRemovesOnlyAfterSpeakerAndThenReleasesServices() async throws {
        let routes = QuitTestRoutes()
        let hardware = QuitTestHardware()
        let store = AudioStore(hardware: hardware, routes: routes)
        let plan = try await store.prepareToQuit()
        XCTAssertTrue(plan.requiresConfirmation)
        try await store.confirmQuit()
        XCTAssertEqual(routes.leaves, 1)
        XCTAssertEqual(routes.shutdowns, 1)
        XCTAssertTrue(routes.closed)
        let writes = await hardware.writes
        let stops = await hardware.stops
        XCTAssertEqual(writes, ["speaker"])
        XCTAssertEqual(stops, 1)
        do { try await store.confirmQuit(); XCTFail("A completed exit cannot commit again") }
        catch {}
        XCTAssertEqual(routes.leaves, 1)
    }

    func testQuitWithoutOwnedFlowDoesNotSwitchOutput() async throws {
        let routes = QuitTestRoutes()
        routes.owned = nil
        let hardware = QuitTestHardware()
        let store = AudioStore(hardware: hardware, routes: routes)
        let plan = try await store.prepareToQuit()
        XCTAssertFalse(plan.requiresConfirmation)
        try await store.confirmQuit()
        let writes = await hardware.writes
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(routes.leaves, 0)
        XCTAssertEqual(routes.shutdowns, 1)
    }

    func testFailedCleanupKeepsAdmissionOpenWithoutDisplayingAnExitError() async throws {
        let routes = QuitTestRoutes()
        routes.failCleanup = true
        let hardware = QuitTestHardware()
        let store = AudioStore(hardware: hardware, routes: routes)
        _ = try await store.prepareToQuit()
        do { try await store.confirmQuit(); XCTFail("Cleanup must fail") }
        catch {}
        XCTAssertFalse(store.isPreparingToQuit)
        XCTAssertNotEqual(store.feedbackKind, .failure)
        XCTAssertFalse(store.feedback.contains("旧音频流清理失败"))
        XCTAssertFalse(routes.closed)
        XCTAssertEqual(routes.shutdowns, 0)
        // Failure must not reopen a closed gate: it never closed one in the first place.
        routes.failCleanup = false
        _ = try await store.prepareToQuit()
        store.cancelQuit()
        XCTAssertFalse(store.isPreparingToQuit)
        try await store.shutdown()
    }

    func testPreflightFailureReturnsToRunningWithoutChangingOutput() async {
        let routes = QuitTestRoutes()
        routes.failPreflight = true
        let hardware = QuitTestHardware()
        let store = AudioStore(hardware: hardware, routes: routes)
        do { _ = try await store.prepareToQuit(); XCTFail("Unknown must not become no-owned-flow") }
        catch {}
        XCTAssertFalse(store.isPreparingToQuit)
        XCTAssertFalse(routes.closed)
        let writes = await hardware.writes
        XCTAssertTrue(writes.isEmpty)
        try? await store.shutdown()
    }

    func testConfirmationUsesExplicitSpeakerWarningAndEscapeCancels() {
        let plan = AudioExitPlan(ownedStream: QuitTestRoutes.evidence)
        let alert = QuitAlerts.confirmation(for: plan)
        XCTAssertEqual(alert.messageText, expectedLocalized("Quit ToneHop?", "退出 ToneHop？"))
        XCTAssertTrue(alert.informativeText.contains(expectedLocalized("and switch output to your Mac’s built-in speakers.", "并将声音输出切换到 Mac 自带扬声器。")))
        XCTAssertFalse(alert.informativeText.contains(expectedLocalized("audio stream", "音频流")))
        XCTAssertEqual(alert.buttons.map(\.title), [expectedLocalized("Switch and Quit", "切换并退出"), expectedLocalized("Cancel", "取消")])
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
    }

    func testQuitExplanationPreservesMixedLanguageReceiverName() {
        let name = "Bedroom 卧室 %@ 🎧"
        let plan = AudioExitPlan(ownedStream: OwnedRouteExitEvidence(receiverID: "receiver", streamUID: "stream", name: name))
        let alert = QuitAlerts.confirmation(for: plan)
        XCTAssertEqual(alert.informativeText,
                       expectedLocalized("This will disconnect audio from “\(name)” and switch output to your Mac’s built-in speakers.",
                                         "将断开与“\(name)”的音频连接，并将声音输出切换到 Mac 自带扬声器。"))
    }

    func testFailedObserverRegistrationRetriesAndClearsWarningWithoutRestart() async throws {
        let routes = QuitTestRoutes()
        let hardware = QuitTestHardware(registrationFailures: 1)
        let store = AudioStore(hardware: hardware, routes: routes,
                               observerRetryDelay: .milliseconds(30), pollingInterval: .milliseconds(5))
        store.start()
        await waitUntil { store.catalogWarning?.contains(expectedLocalized("System notifications are unavailable", "系统状态通知暂不可用")) == true }
        await waitUntil { store.catalogWarning?.contains(expectedLocalized("System notifications are unavailable", "系统状态通知暂不可用")) != true && !store.devices.isEmpty }
        // Other independent evidence warnings survive listener recovery.
        XCTAssertTrue(store.catalogWarning?.contains(expectedLocalized("The current output is not confirmed", "当前输出待确认")) == true)
        let registrations = await hardware.registrations
        XCTAssertEqual(registrations, 2)
        try await store.shutdown()
        try await Task.sleep(for: .milliseconds(45))
        let after = await hardware.registrations
        XCTAssertEqual(after, registrations)
    }

    func testPendingBackgroundReadErrorsStayOutOfPanelWhileCheckingQuit() async throws {
        for status in [kAudioHardwareBadObjectError, kAudioHardwareBadDeviceError] {
            let routes = QuitTestRoutes()
            let hardware = SuspendableQuitHardware()
            let store = AudioStore(hardware: hardware, routes: routes)
            store.refresh()
            await waitUntil { !store.devices.isEmpty && !store.isRefreshing }
            let displayedDevices = store.devices
            let displayedFeedback = store.feedback
            let displayedWarning = store.catalogWarning

            hardware.pauseNextSnapshot = true
            store.refresh()
            await waitUntil { hardware.hasPendingSnapshot }
            routes.pauseNextPreflight = true
            let preparing = Task { try await store.prepareToQuit() }
            await waitUntil { routes.hasPendingPreflight }
            hardware.resumeSnapshot(.failure(AudioServiceError.system(operation: "读取音频属性", status: status)))
            await waitUntil { !store.isRefreshing }

            XCTAssertEqual(store.devices, displayedDevices)
            XCTAssertEqual(store.currentDeviceID, hardware.speaker.id)
            XCTAssertEqual(store.feedback, displayedFeedback)
            XCTAssertEqual(store.feedbackKind, .neutral)
            XCTAssertEqual(store.catalogWarning, displayedWarning)
            let reads = hardware.snapshotReads
            store.refresh()
            store.refresh()
            await Task.yield()
            XCTAssertEqual(hardware.snapshotReads, reads)

            routes.resumePreflight()
            _ = try await preparing.value
            store.cancelQuit()
            await waitUntil { hardware.snapshotReads == reads + 1 && !store.isRefreshing }
            try await store.shutdown()
        }
    }

    func testPendingBackgroundWarningsStayOutOfPanelUntilCancelRefreshes() async throws {
        let routes = QuitTestRoutes()
        let hardware = SuspendableQuitHardware()
        let store = AudioStore(hardware: hardware, routes: routes)
        store.refresh()
        await waitUntil { !store.devices.isEmpty && !store.isRefreshing }
        let displayedDevices = store.devices
        let displayedFeedback = store.feedback
        let displayedWarning = store.catalogWarning

        hardware.pauseNextSnapshot = true
        store.refresh()
        await waitUntil { hardware.hasPendingSnapshot }
        _ = try await store.prepareToQuit()
        hardware.resumeSnapshot(.success(.init(devices: [], currentDeviceID: nil, systemSoundDeviceID: nil,
                                              warnings: ["退出期间读取音频属性失败（!obj / !dev）"])))
        await waitUntil { !store.isRefreshing }
        XCTAssertEqual(store.devices, displayedDevices)
        XCTAssertEqual(store.currentDeviceID, hardware.speaker.id)
        XCTAssertEqual(store.feedback, displayedFeedback)
        XCTAssertEqual(store.catalogWarning, displayedWarning)
        let reads = hardware.snapshotReads
        store.refresh()
        store.refresh()
        await Task.yield()
        XCTAssertEqual(hardware.snapshotReads, reads)

        hardware.current = hardware.display.id
        hardware.warnings = ["恢复后的普通目录提示"]
        store.cancelQuit()
        await waitUntil { hardware.snapshotReads == reads + 1 && !store.isRefreshing }
        XCTAssertEqual(store.currentDeviceID, hardware.display.id)
        XCTAssertEqual(store.catalogWarning, "恢复后的普通目录提示")
        XCTAssertEqual(store.feedbackKind, .neutral)
        try await store.shutdown()
    }

    func testPendingBackgroundFailureDoesNotPublishDuringQuitCleanup() async throws {
        let routes = QuitTestRoutes()
        let hardware = SuspendableQuitHardware()
        let store = AudioStore(hardware: hardware, routes: routes)
        store.refresh()
        await waitUntil { !store.devices.isEmpty && !store.isRefreshing }
        let displayedDevices = store.devices
        let displayedFeedback = store.feedback
        let displayedWarning = store.catalogWarning

        hardware.pauseNextSnapshot = true
        store.refresh()
        await waitUntil { hardware.hasPendingSnapshot }
        _ = try await store.prepareToQuit()
        routes.pauseNextCleanup = true
        let confirming = Task { try await store.confirmQuit() }
        await waitUntil { routes.hasPendingCleanup }
        hardware.resumeSnapshot(.failure(AudioServiceError.system(operation: "读取音频属性",
                                                                  status: kAudioHardwareBadObjectError)))
        await waitUntil { !store.isRefreshing }
        XCTAssertEqual(store.devices, displayedDevices)
        XCTAssertEqual(store.currentDeviceID, hardware.speaker.id)
        XCTAssertEqual(store.feedback, displayedFeedback)
        XCTAssertEqual(store.feedbackKind, .neutral)
        XCTAssertEqual(store.catalogWarning, displayedWarning)
        let reads = hardware.snapshotReads
        store.refresh()
        await Task.yield()
        XCTAssertEqual(hardware.snapshotReads, reads)
        routes.resumeCleanup()
        try await confirming.value
        XCTAssertEqual(routes.shutdowns, 1)
    }

    func testCancelQuitRestoresOrdinaryBackgroundErrorFeedback() async throws {
        let routes = QuitTestRoutes()
        let hardware = SuspendableQuitHardware()
        let store = AudioStore(hardware: hardware, routes: routes)
        store.refresh()
        await waitUntil { !store.devices.isEmpty && !store.isRefreshing }
        _ = try await store.prepareToQuit()
        let reads = hardware.snapshotReads
        store.refresh()
        store.refresh()
        await Task.yield()
        XCTAssertEqual(hardware.snapshotReads, reads)

        hardware.pauseNextSnapshot = true
        store.cancelQuit()
        await waitUntil { hardware.hasPendingSnapshot }
        let failure = AudioServiceError.system(operation: "读取音频属性", status: kAudioHardwareBadDeviceError)
        hardware.resumeSnapshot(.failure(failure))
        await waitUntil { store.feedbackKind == .failure }
        XCTAssertEqual(store.feedback, failure.localizedDescription)
        XCTAssertNil(store.currentDeviceID)
        XCTAssertTrue(store.devices.allSatisfy { !$0.isAvailable })
        XCTAssertEqual(hardware.snapshotReads, reads + 1)
        try await store.shutdown()
    }

    func testFailedQuitInspectionResumesDeferredRefreshWithNormalWarnings() async throws {
        let routes = QuitTestRoutes()
        let hardware = SuspendableQuitHardware()
        let store = AudioStore(hardware: hardware, routes: routes)
        store.refresh()
        await waitUntil { !store.devices.isEmpty && !store.isRefreshing }
        routes.pauseNextPreflight = true
        let preparing = Task { try await store.prepareToQuit() }
        await waitUntil { routes.hasPendingPreflight }
        let reads = hardware.snapshotReads
        store.refresh()
        hardware.warnings = ["普通运行期间的设备诊断"]
        routes.failPreflight = true
        routes.resumePreflight()
        do { _ = try await preparing.value; XCTFail("Inspection must fail") }
        catch {}
        await waitUntil { hardware.snapshotReads == reads + 1 && !store.isRefreshing }
        XCTAssertFalse(store.isPreparingToQuit)
        XCTAssertEqual(store.catalogWarning, "普通运行期间的设备诊断")
        XCTAssertNotEqual(store.feedbackKind, .failure)
        XCTAssertFalse(store.feedback.contains("旧流状态未知"))
        try await store.shutdown()
    }

    func testExistingSelectionStillPublishesReadbackWhileQuitWaitsForIt() async throws {
        let routes = QuitTestRoutes()
        let hardware = SuspendableQuitHardware()
        let store = AudioStore(hardware: hardware, routes: routes, timeout: .seconds(1))
        store.refresh()
        await waitUntil { !store.devices.isEmpty && !store.isRefreshing }
        hardware.pauseNextSnapshot = true
        store.select(hardware.display)
        await waitUntil { hardware.hasPendingSnapshot }
        let preparing = Task { try await store.prepareToQuit() }
        await waitUntil { store.isPreparingToQuit }
        hardware.resumeSnapshot(.success(hardware.currentSnapshot))
        await waitUntil { !store.isSwitching }
        _ = try await preparing.value
        XCTAssertEqual(store.currentDeviceID, hardware.display.id)
        XCTAssertEqual(store.feedbackKind, .success)
        XCTAssertEqual(hardware.writes, ["display"])
        store.cancelQuit()
        try await store.shutdown()
    }

    func testCancelledQuitDiscardsLateBackgroundErrorsAndWarningsBeforeFreshRead() async throws {
        try await assertLateBackgroundResultsAreDiscarded(after: .cancel)
    }

    func testFailedQuitInspectionDiscardsLateBackgroundErrorsAndWarningsBeforeFreshRead() async throws {
        try await assertLateBackgroundResultsAreDiscarded(after: .preflightFailure)
    }

    func testFailedQuitCleanupDiscardsLateBackgroundErrorsAndWarningsBeforeFreshRead() async throws {
        try await assertLateBackgroundResultsAreDiscarded(after: .cleanupFailure)
    }

    private enum QuitCompletion { case cancel, preflightFailure, cleanupFailure }

    private func assertLateBackgroundResultsAreDiscarded(after completion: QuitCompletion) async throws {
        let lateResults: [Result<CoreAudioSnapshot, any Error>] = [
            .failure(AudioServiceError.system(operation: "读取音频属性", status: kAudioHardwareBadObjectError)),
            .failure(AudioServiceError.system(operation: "读取音频属性", status: kAudioHardwareBadDeviceError)),
            .success(.init(devices: [], currentDeviceID: nil, systemSoundDeviceID: nil,
                           warnings: ["退出周期的迟到 !obj / !dev 警告"]))
        ]
        for lateResult in lateResults {
            let routes = QuitTestRoutes()
            let hardware = SuspendableQuitHardware()
            let store = AudioStore(hardware: hardware, routes: routes)
            store.refresh()
            await waitUntil { !store.devices.isEmpty && !store.isRefreshing }
            let displayedDevices = store.devices
            let displayedFeedback = store.feedback
            let displayedWarning = store.catalogWarning
            hardware.pauseNextSnapshot = true
            store.refresh()
            await waitUntil { hardware.hasPendingSnapshot }

            switch completion {
            case .cancel:
                _ = try await store.prepareToQuit()
                store.cancelQuit()
            case .preflightFailure:
                routes.failPreflight = true
                do { _ = try await store.prepareToQuit(); XCTFail("Inspection must fail") }
                catch {}
            case .cleanupFailure:
                _ = try await store.prepareToQuit()
                routes.failCleanup = true
                do { try await store.confirmQuit(); XCTFail("Cleanup must fail") }
                catch {}
            }
            XCTAssertFalse(store.isPreparingToQuit)
            let reads = hardware.snapshotReads
            // Hold the fresh read separately so it cannot hide a brief stale
            // error/warning publication by overwriting it before assertions.
            hardware.pauseNextSnapshot = true
            hardware.resumeSnapshot(lateResult)
            await waitUntil { hardware.snapshotReads == reads + 1 && hardware.hasPendingSnapshot }
            XCTAssertEqual(store.devices, displayedDevices)
            XCTAssertEqual(store.currentDeviceID, hardware.speaker.id)
            XCTAssertEqual(store.feedback, displayedFeedback)
            XCTAssertEqual(store.feedbackKind, .neutral)
            XCTAssertEqual(store.catalogWarning, displayedWarning)

            hardware.current = hardware.display.id
            hardware.warnings = ["新读取的普通运行诊断"]
            hardware.resumeSnapshot(.success(hardware.currentSnapshot))
            await waitUntil { !store.isRefreshing }
            XCTAssertEqual(store.currentDeviceID, hardware.display.id)
            XCTAssertEqual(store.catalogWarning, "新读取的普通运行诊断")
            XCTAssertEqual(hardware.snapshotReads, reads + 1)
            try await store.shutdown()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class QuitTestRoutes: PrivateRouting {
    static let evidence = OwnedRouteExitEvidence(receiverID: "receiver", streamUID: "stream", name: "Receiver")
    var onChange: (() -> Void)?
    var owned: OwnedRouteExitEvidence? = evidence
    var shutdowns = 0
    var leaves = 0
    var closed = false
    var failCleanup = false
    var failPreflight = false
    var pauseNextPreflight = false
    var pauseNextCleanup = false
    private var pendingPreflight: CheckedContinuation<Void, Never>?
    private var pendingCleanup: CheckedContinuation<Void, Never>?
    var hasPendingPreflight: Bool { pendingPreflight != nil }
    var hasPendingCleanup: Bool { pendingCleanup != nil }
    func start() {}
    func stop() {}
    func beginShutdown() { closed = true }
    func snapshot() -> PrivateRouteSnapshot { .init(routes: [], warning: nil, diagnostics: "fixture") }
    func select(identifier: String) async throws {}
    func prepareToLeave() async throws {}
    func completedLeave() async throws {
        leaves += 1
        if pauseNextCleanup {
            pauseNextCleanup = false
            await withCheckedContinuation { pendingCleanup = $0 }
        }
        if failCleanup { throw AudioServiceError.unavailable("旧音频流清理失败") }
        owned = nil
    }
    func ownedStreamForExit() async throws -> OwnedRouteExitEvidence? {
        if pauseNextPreflight {
            pauseNextPreflight = false
            await withCheckedContinuation { pendingPreflight = $0 }
        }
        if failPreflight { throw AudioServiceError.unavailable("旧流状态未知") }
        return owned
    }
    func shutdown() async throws { shutdowns += 1 }
    func resumePreflight() {
        let pending = pendingPreflight
        pendingPreflight = nil
        pending?.resume()
    }
    func resumeCleanup() {
        let pending = pendingCleanup
        pendingCleanup = nil
        pending?.resume()
    }
}

@MainActor
private final class SuspendableQuitHardware: AudioHardwareProviding {
    let speaker = AudioDevice(id: "hal:speaker", name: "Speakers", transport: .speaker, backend: .coreAudio(uid: "speaker"))
    let display = AudioDevice(id: "hal:display", name: "Display", transport: .display, backend: .coreAudio(uid: "display"))
    var current = "hal:speaker"
    var warnings = ["既有设备提示"]
    var snapshotReads = 0
    var writes: [String] = []
    var pauseNextSnapshot = false
    private var pendingSnapshot: CheckedContinuation<CoreAudioSnapshot, any Error>?
    var hasPendingSnapshot: Bool { pendingSnapshot != nil }
    var currentSnapshot: CoreAudioSnapshot {
        .init(devices: [speaker, display], currentDeviceID: current, systemSoundDeviceID: nil, warnings: warnings)
    }
    nonisolated func beginShutdown() {}
    func snapshot() async throws -> CoreAudioSnapshot {
        snapshotReads += 1
        if pauseNextSnapshot {
            pauseNextSnapshot = false
            return try await withCheckedThrowingContinuation { pendingSnapshot = $0 }
        }
        return currentSnapshot
    }
    func resumeSnapshot(_ result: Result<CoreAudioSnapshot, any Error>) {
        let pending = pendingSnapshot
        pendingSnapshot = nil
        pending?.resume(with: result)
    }
    func builtInSpeaker() async throws -> AudioDevice { speaker }
    func select(uid: String) async throws { writes.append(uid); current = "hal:\(uid)" }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws {}
    func stopObserving() async {}
}

private actor QuitTestHardware: AudioHardwareProviding {
    let speaker = AudioDevice(id: "hal:speaker", name: "Speakers", transport: .speaker, backend: .coreAudio(uid: "speaker"))
    var current = "hal:airplay"
    var writes: [String] = []
    var stops = 0
    var registrations = 0
    let registrationFailures: Int
    init(registrationFailures: Int = 0) { self.registrationFailures = registrationFailures }
    nonisolated func beginShutdown() {}
    func snapshot() -> CoreAudioSnapshot {
        .init(devices: [speaker], currentDeviceID: current, systemSoundDeviceID: nil, warnings: [])
    }
    func builtInSpeaker() -> AudioDevice { speaker }
    func select(uid: String) { writes.append(uid); current = "hal:\(uid)" }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) throws {
        registrations += 1
        if registrations <= registrationFailures { throw AudioServiceError.unavailable("fixture listener failure") }
    }
    func stopObserving() { stops += 1 }
}
