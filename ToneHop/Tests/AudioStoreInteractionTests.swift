import Foundation
import XCTest
@testable import ToneHop

@MainActor
final class AudioStoreInteractionTests: XCTestCase {
    func testQuitAdmissionPausesSynchronouslyAndDrainsBeforeOwnershipInspection() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes)
        await load(store)
        let drain = StoreInteractionBarrier()
        defer { drain.release() }
        store.onInteractionChange = { phase, active in trace.append("\(phase):\(active)") }
        store.drainInteractions = {
            trace.append("drain:begin")
            await drain.wait()
            trace.append("drain:end")
        }
        var results: [AudioSelectionResult] = []
        store.onSelectionResult = { results.append($0) }

        store.beginQuitPreparation()
        XCTAssertTrue(store.isPreparingToQuit)
        XCTAssertEqual(trace.values, ["quitting:true"], "Admission must pause interactions before an async task can run.")
        let refused = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))
        store.select(target: .hal(uid: hardware.externalUID), request: refused)
        XCTAssertEqual(results, [.init(request: refused, outcome: .ignored)])
        XCTAssertFalse(store.isSwitching)

        let preparing = Task { try await store.prepareToQuit() }
        await waitUntil { drain.isWaiting }
        XCTAssertEqual(routes.ownershipReads, 0)
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertEqual(hardware.shutdownSignal.count, 0)
        XCTAssertFalse(routes.closed)
        XCTAssertEqual(trace.values, ["quitting:true", "drain:begin"])

        drain.release()
        let plan = try await preparing.value
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertEqual(trace.values, ["quitting:true", "drain:begin", "drain:end", "ownership"])
        store.cancelQuit()
        XCTAssertFalse(store.isPreparingToQuit)
        XCTAssertEqual(trace.values.last, "quitting:false")
        XCTAssertEqual(hardware.shutdownSignal.count, 0, "Reversible quit must leave the HAL gate running.")
        XCTAssertFalse(routes.closed)
        XCTAssertEqual(routes.shutdowns, 0)

        let resumed = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))
        store.select(target: .hal(uid: hardware.externalUID), request: resumed)
        await waitUntil { !store.isSwitching }
        XCTAssertEqual(results.filter { $0.request == resumed }, [.init(request: resumed, outcome: .selected)])
        XCTAssertEqual(hardware.writes, [hardware.externalUID])
        XCTAssertEqual(hardware.shutdownSignal.count, 0)
        try await store.shutdown()
    }

    func testAcceptedSelectionPausesSynchronouslyAndWaitsForDrainBeforeAnyRouteWrite() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes)
        await load(store)
        let drain = StoreInteractionBarrier()
        defer { drain.release() }
        var results: [AudioSelectionResult] = []
        store.onSelectionResult = { results.append($0) }
        store.onInteractionChange = { phase, active in trace.append("\(phase):\(active)") }
        store.drainInteractions = {
            trace.append("drain:begin")
            await drain.wait()
            trace.append("drain:end")
        }

        let selected = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))
        store.select(target: .hal(uid: hardware.externalUID), request: selected)
        XCTAssertTrue(store.isSwitching)
        XCTAssertEqual(trace.values, ["switching:true"])
        XCTAssertTrue(results.isEmpty)
        let busy = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))
        store.select(target: .hal(uid: hardware.speakerUID), request: busy)
        XCTAssertEqual(results, [.init(request: busy, outcome: .ignored)])

        await waitUntil { drain.isWaiting }
        XCTAssertEqual(trace.values, ["switching:true", "drain:begin"])
        XCTAssertEqual(routes.preparedLeaves, 0)
        XCTAssertTrue(hardware.writes.isEmpty)
        drain.release()
        await waitUntil { !store.isSwitching }

        XCTAssertEqual(results.filter { $0.request == selected }, [.init(request: selected, outcome: .selected)])
        XCTAssertEqual(trace.values, ["switching:true", "drain:begin", "drain:end", "prepareLeave",
                                     "select:\(hardware.externalUID)", "completeLeave", "switching:false"])
        XCTAssertEqual(hardware.writes, [hardware.externalUID])
        XCTAssertEqual(store.currentDeviceID, hardware.external.id)
        let readsBeforeRefresh = hardware.snapshotReads
        store.refresh()
        await waitUntil { hardware.snapshotReads > readsBeforeRefresh && !store.isRefreshing }
        XCTAssertEqual(results.count, 2, "A later catalog publication must not redeliver the completed request.")
        try await store.shutdown()
    }

    func testMissingRequestReturnsItsOwnImmediateFailureWithoutPausing() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes)
        await load(store)
        var results: [AudioSelectionResult] = []
        store.onSelectionResult = { results.append($0) }
        store.onInteractionChange = { phase, active in trace.append("\(phase):\(active)") }
        store.drainInteractions = { trace.append("drain") }

        let missing = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))
        store.select(target: .hal(uid: "absent-complete-UID"), request: missing)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.last?.request, missing)
        guard case let .failed(message) = results.last?.outcome else {
            try await store.shutdown()
            return XCTFail("A missing stable identity must fail this request, rather than become an ignored or successful request.")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(store.isSwitching)
        XCTAssertTrue(trace.values.isEmpty)
        XCTAssertTrue(hardware.writes.isEmpty)
        try await store.shutdown()
    }

    func testAlreadySelectedRequestWaitsForFreshConfirmationAndPreservesEarlierFeedback() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes)
        await load(store)
        let missing = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))
        store.select(target: .hal(uid: "missing-UID"), request: missing)
        let previousFeedback = store.feedback
        var results: [AudioSelectionResult] = []
        store.onSelectionResult = { results.append($0) }
        store.onInteractionChange = { phase, active in trace.append("\(phase):\(active)") }
        store.drainInteractions = { trace.append("drain") }
        routes.pauseNextFreshSnapshot = true
        defer { routes.resumeFreshSnapshot() }

        let request = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))
        store.select(target: .hal(uid: hardware.speakerUID), request: request)
        XCTAssertTrue(store.isSwitching)
        XCTAssertTrue(results.isEmpty, "The cached checkmark cannot synchronously certify current system output.")
        await waitUntil { routes.hasPendingFreshSnapshot }
        XCTAssertEqual(trace.values, ["switching:true", "drain"])
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertEqual(routes.preparedLeaves, 0)

        routes.resumeFreshSnapshot()
        await waitUntil { !store.isSwitching }
        XCTAssertEqual(results, [.init(request: request, outcome: .alreadySelected)])
        XCTAssertEqual(trace.values, ["switching:true", "drain", "switching:false"])
        XCTAssertEqual(store.feedback, previousFeedback)
        XCTAssertEqual(store.feedbackKind, .failure, "A no-op confirmation must not erase an earlier failure.")
        XCTAssertEqual(routes.freshSnapshotReads, 1)
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertEqual(routes.preparedLeaves, 0)
        try await store.shutdown()
    }

    func testShortcutToCachedCurrentDeviceSwitchesBackAfterUnpublishedExternalChange() async throws {
        try await verifyUnpublishedExternalChange(origin: .shortcut(bindingID: UUID()))
    }

    func testPointerToCachedCurrentDeviceSwitchesBackAfterUnpublishedExternalChange() async throws {
        try await verifyUnpublishedExternalChange(origin: .pointer)
    }

    func testExternalChangeWhileFreshPrivateReadWaitsIsCheckedByLaterHALRead() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes)
        await load(store)
        routes.pauseNextFreshSnapshot = true
        defer { routes.resumeFreshSnapshot() }
        var results: [AudioSelectionResult] = []
        store.onSelectionResult = { results.append($0) }
        let request = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))

        store.select(target: .hal(uid: hardware.speakerUID), request: request)
        await waitUntil { routes.hasPendingFreshSnapshot }
        hardware.current = hardware.external.id
        routes.resumeFreshSnapshot()
        await waitUntil { !store.isSwitching }

        XCTAssertEqual(results, [.init(request: request, outcome: .selected)])
        XCTAssertEqual(hardware.writes, [hardware.speakerUID], "HAL must be read after the suspended private read, not before it.")
        XCTAssertEqual(store.currentDeviceID, hardware.speaker.id)
        try await store.shutdown()
    }

    func testCachedSelectedReceiverNeedsFreshPrivateEvidenceBeforeReturningAlreadySelected() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        hardware.includeReceiver = true
        hardware.current = hardware.stream.id
        routes.includeReceiver = true
        let store = AudioStore(hardware: hardware, routes: routes)
        await load(store)
        XCTAssertEqual(store.currentDeviceID, "route:\(routes.receiverID)")
        // The HAL stream and cached selected flag remain unchanged, but the
        // fresh worker result no longer confirms SystemAudio selection.
        let route = PrivateAudioRoute(identifier: routes.receiverID, name: "Receiver", uid: hardware.streamUID,
                                      isSelected: false, canSelect: true, transport: "airplay")
        routes.freshSnapshotOverride = .init(routes: [route], warning: nil, diagnostics: "fresh unselected fixture",
                                            confirmedShortcutIdentifiers: [routes.receiverID])
        routes.onSelect = { [weak routes] in routes?.freshSnapshotOverride = nil }
        var results: [AudioSelectionResult] = []
        store.onSelectionResult = { results.append($0) }
        let request = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))

        store.select(target: .receiver(identifier: routes.receiverID), request: request)
        await waitUntil { !store.isSwitching }

        XCTAssertEqual(routes.freshSnapshotReads, 1)
        XCTAssertEqual(routes.selections, [routes.receiverID], "Cached private selection must not suppress the normal route strategy.")
        XCTAssertEqual(results, [.init(request: request, outcome: .selected)])
        XCTAssertTrue(hardware.writes.isEmpty)
        try await store.shutdown()
    }

    func testNoOpConfirmationTimeoutStaysLockedUntilFreshReadReturnsWithoutWriting() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes, timeout: .milliseconds(60))
        await load(store)
        routes.pauseNextFreshSnapshot = true
        defer { routes.resumeFreshSnapshot() }
        var results: [AudioSelectionResult] = []
        store.onSelectionResult = { results.append($0) }
        let request = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))

        store.select(target: .hal(uid: hardware.speakerUID), request: request)
        await waitUntil { routes.hasPendingFreshSnapshot }
        await waitUntil { !results.isEmpty }
        XCTAssertTrue(store.isSwitching)
        guard case .failed = results.first?.outcome else {
            routes.resumeFreshSnapshot()
            try await store.shutdown()
            return XCTFail("The original deadline includes no-op confirmation.")
        }
        let failure = store.feedback
        routes.resumeFreshSnapshot()
        await waitUntil { !store.isSwitching && store.feedbackKind == .neutral }
        XCTAssertEqual(results.count, 1, "A late fresh read cannot change a timeout into alreadySelected.")
        XCTAssertEqual(results, [.init(request: request, outcome: .failed(failure))])
        XCTAssertEqual(store.feedbackKind, .neutral, "A subsequent fresh target read dismisses presentation without changing the timeout outcome.")
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertTrue(routes.selections.isEmpty)
        XCTAssertEqual(routes.preparedLeaves, 0)
        try await store.shutdown()
    }

    func testQuitWaitsForNoOpConfirmationBeforeInspectingOwnership() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes)
        await load(store)
        routes.pauseNextFreshSnapshot = true
        defer { routes.resumeFreshSnapshot() }
        var results: [AudioSelectionResult] = []
        store.onSelectionResult = { results.append($0) }
        let request = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))
        store.select(target: .hal(uid: hardware.speakerUID), request: request)
        await waitUntil { routes.hasPendingFreshSnapshot }

        store.beginQuitPreparation()
        let preparing = Task { try await store.prepareToQuit() }
        await Task.yield()
        XCTAssertEqual(routes.ownershipReads, 0)
        XCTAssertTrue(store.isSwitching)
        routes.resumeFreshSnapshot()
        _ = try await preparing.value
        XCTAssertEqual(results, [.init(request: request, outcome: .alreadySelected)])
        XCTAssertEqual(routes.ownershipReads, 1)
        XCTAssertTrue(hardware.writes.isEmpty)
        store.cancelQuit()
        try await store.shutdown()
    }

    func testShutdownDuringNoOpConfirmationRejectsLateResultAndDoesNotWrite() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes)
        await load(store)
        routes.pauseNextFreshSnapshot = true
        defer { routes.resumeFreshSnapshot() }
        var results: [AudioSelectionResult] = []
        var publications = 0
        store.onSelectionResult = { results.append($0) }
        store.onCatalogChange = { _, _ in publications += 1 }
        let request = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))
        store.select(target: .hal(uid: hardware.speakerUID), request: request)
        await waitUntil { routes.hasPendingFreshSnapshot }

        let stopping = Task { try await store.shutdown() }
        await waitUntil { hardware.shutdownSignal.count == 1 }
        routes.resumeFreshSnapshot()
        try await stopping.value
        XCTAssertEqual(results, [.init(request: request, outcome: .ignored)])
        XCTAssertEqual(publications, 0, "A fresh read returning after close must not publish a no-op confirmation.")
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertTrue(routes.selections.isEmpty)
        XCTAssertEqual(routes.preparedLeaves, 0)
    }

    func testOlderBackgroundSnapshotCannotOverwriteFreshNoOpConfirmation() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes)
        await load(store)
        hardware.current = hardware.external.id
        hardware.pauseNextSnapshot = true
        defer { hardware.resumeSnapshot() }
        store.refresh()
        await waitUntil { hardware.hasPendingSnapshot }
        hardware.current = hardware.speaker.id
        var results: [AudioSelectionResult] = []
        store.onSelectionResult = { results.append($0) }
        let request = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))

        store.select(target: .hal(uid: hardware.speakerUID), request: request)
        await waitUntil { !store.isSwitching }
        XCTAssertEqual(results, [.init(request: request, outcome: .alreadySelected)])
        hardware.resumeSnapshot()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(store.currentDeviceID, hardware.speaker.id)
        XCTAssertTrue(hardware.writes.isEmpty)
        try await store.shutdown()
    }

    func testTimedOutSelectionReportsOnlyOnceAndStaysPausedUntilNativeReturn() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes, timeout: .milliseconds(60))
        await load(store)
        hardware.pauseNextSelection = true
        defer { hardware.resumeSelection() }
        var results: [AudioSelectionResult] = []
        store.onSelectionResult = { results.append($0) }
        store.onInteractionChange = { phase, active in trace.append("\(phase):\(active)") }
        let request = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))
        store.select(target: .hal(uid: hardware.externalUID), request: request)
        await waitUntil { hardware.hasPendingSelection }
        await waitUntil { results.contains(where: { $0.request == request }) }
        XCTAssertTrue(store.isSwitching, "Task cancellation cannot prove the native write has returned.")
        XCTAssertFalse(trace.values.contains("switching:false"))
        XCTAssertEqual(results.filter { $0.request == request }.count, 1)
        if case .failed = results.first?.outcome {} else { XCTFail("The deadline must deliver a typed failure.") }

        let busy = AudioSelectionRequest(origin: .shortcut(bindingID: UUID()))
        store.select(target: .hal(uid: hardware.speakerUID), request: busy)
        XCTAssertEqual(results.last, .init(request: busy, outcome: .ignored))
        hardware.resumeSelection()
        await waitUntil { !store.isSwitching && store.currentDeviceID == hardware.external.id }
        XCTAssertEqual(results.filter { $0.request == request }.count, 1,
                       "A late system return/readback cannot turn a delivered timeout into a second result.")
        XCTAssertEqual(trace.values.filter { $0 == "switching:false" }.count, 1)
        XCTAssertEqual(hardware.writes, [hardware.externalUID])
        try await store.shutdown()
    }

    func testLateVolumeResolutionCannotReplaceNewerCatalogTargetsOrPublishThemAgain() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        hardware.includeReceiver = true
        hardware.current = hardware.stream.id
        routes.includeReceiver = true
        let store = AudioStore(hardware: hardware, routes: routes)
        await load(store)
        let receiverID = "route:\(routes.receiverID)"
        let originalReceiver = try XCTUnwrap(store.volumeTargets[receiverID])
        let originalSpeaker = try XCTUnwrap(store.volumeTargets[hardware.speaker.id])
        var publications = 0
        store.onCatalogChange = { _, _ in publications += 1 }

        routes.pauseNextFreshSnapshot = true
        defer { routes.resumeFreshSnapshot() }
        let resolving = Task { try await store.resolveVolumeTarget(deviceID: receiverID) }
        await waitUntil { routes.hasPendingFreshSnapshot }
        // The resolver has already captured HAL object A, then suspended on the
        // private executor. A normal refresh now publishes object B for the same
        // complete UID, plus a new object for another row.
        hardware.streamObject = 201
        hardware.speakerObject = 101
        let readsBeforeRefresh = hardware.snapshotReads
        store.refresh()
        await waitUntil { hardware.snapshotReads > readsBeforeRefresh && !store.isRefreshing }
        let replacementReceiver = try XCTUnwrap(store.volumeTargets[receiverID])
        let replacementSpeaker = try XCTUnwrap(store.volumeTargets[hardware.speaker.id])
        XCTAssertEqual(replacementReceiver.uid, originalReceiver.uid)
        XCTAssertNotEqual(replacementReceiver.generation, originalReceiver.generation)
        XCTAssertNotEqual(replacementSpeaker.generation, originalSpeaker.generation)
        let freshTargets = store.volumeTargets
        let freshBindings = store.volumeBindings
        let freshPublicationCount = publications
        XCTAssertEqual(freshPublicationCount, 1)

        routes.resumeFreshSnapshot()
        do {
            _ = try await resolving.value
            XCTFail("An older association read must fail after a newer catalog publication.")
        } catch {
            XCTAssertEqual(error as? AudioVolumeIssue, .identityChanged)
        }
        XCTAssertEqual(store.volumeTargets, freshTargets, "Stale HAL object A must not invalidate object B's generation.")
        XCTAssertEqual(store.volumeBindings, freshBindings, "An old receiver request must not replace other rows' targets.")
        XCTAssertEqual(publications, freshPublicationCount, "Reject the stale read before publishing or cancelling newer work.")
        XCTAssertEqual(store.lastHardwareSnapshot?.confirmedDeviceObjects[hardware.streamUID], 201)
        XCTAssertTrue(hardware.writes.isEmpty)
        XCTAssertEqual(routes.preparedLeaves, 0)
        try await store.shutdown()
    }

    func testHiddenPanelStopsPollingForTenSecondsButStillReceivesHardwareChanges() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes, pollingInterval: .milliseconds(25))
        store.setPanelVisible(false)
        store.start()
        await waitUntil { !store.devices.isEmpty && !store.isRefreshing && routes.periodicObservation.last == false }
        let settled = hardware.snapshotReads
        try await Task.sleep(for: .seconds(10))
        XCTAssertEqual(hardware.snapshotReads, settled, "Installed listeners must replace hidden periodic HAL reads.")

        hardware.current = hardware.external.id
        hardware.signalChange()
        await waitUntil { store.currentDeviceID == hardware.external.id && !store.isRefreshing }

        let beforeOpening = hardware.snapshotReads
        store.setPanelVisible(true)
        store.setPanelVisible(false)
        store.setPanelVisible(true)
        await waitUntil { hardware.snapshotReads >= beforeOpening + 3 }
        XCTAssertEqual(routes.periodicObservation.last, true, "Rapid toggles must retain the replacement timer.")
        store.setPanelVisible(false)
        await waitUntil { !store.isRefreshing }
        let hidden = hardware.snapshotReads
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(hardware.snapshotReads, hidden)
        try await store.shutdown()
    }

    func testOpeningStartsHardwarePollingWithoutWaitingForTheInterval() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes, pollingInterval: .seconds(30))
        store.setPanelVisible(false)
        store.start()
        await waitUntil { !store.devices.isEmpty && !store.isRefreshing && routes.periodicObservation.last == false }
        let settled = hardware.snapshotReads
        store.setPanelVisible(true)
        await waitUntil { hardware.snapshotReads > settled }
        XCTAssertEqual(routes.periodicObservation.last, true)
        try await store.shutdown()
    }

    func testHiddenHardwareObserverFailureKeepsFallbackUntilRegistrationRecovers() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        hardware.failObservation = true
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes,
                               observerRetryDelay: .milliseconds(50), pollingInterval: .milliseconds(10))
        store.setPanelVisible(false)
        store.start()
        await waitUntil { hardware.snapshotReads >= 4 && hardware.observationAttempts >= 2 }
        XCTAssertEqual(routes.periodicObservation.last, true)
        hardware.failObservation = false
        await waitUntil { routes.periodicObservation.last == false && !store.isRefreshing }
        let recovered = hardware.snapshotReads
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hardware.snapshotReads, recovered)
        try await store.shutdown()
    }

    func testHiddenHardwareObservationInFlightKeepsPrivateAndHardwareFallback() async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        hardware.holdObservation = true
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes, pollingInterval: .milliseconds(10))
        store.setPanelVisible(false)
        store.start()
        await waitUntil { hardware.hasPendingObservation && hardware.snapshotReads >= 3 }
        XCTAssertEqual(routes.periodicObservation.last, true, "Registration has not succeeded yet.")
        hardware.resumeObservation()
        await waitUntil { routes.periodicObservation.last == false && !store.isRefreshing }
        let installed = hardware.snapshotReads
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hardware.snapshotReads, installed)
        try await store.shutdown()
    }

    private func load(_ store: AudioStore) async {
        store.refresh()
        await waitUntil { !store.devices.isEmpty && !store.isRefreshing }
    }

    private func verifyUnpublishedExternalChange(origin: AudioSelectionOrigin) async throws {
        let trace = StoreInteractionTrace()
        let hardware = StoreInteractionHardware(trace: trace)
        let routes = StoreInteractionRoutes(trace: trace)
        let store = AudioStore(hardware: hardware, routes: routes)
        await load(store)
        hardware.current = hardware.external.id
        XCTAssertEqual(store.currentDeviceID, hardware.speaker.id, "The fixture deliberately withholds the external notification.")
        var results: [AudioSelectionResult] = []
        store.onSelectionResult = { results.append($0) }

        switch origin {
        case .pointer: store.select(hardware.speaker)
        case .shortcut:
            store.select(target: .hal(uid: hardware.speakerUID), request: .init(origin: origin))
        }
        await waitUntil { !store.isSwitching }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.request.origin, origin)
        XCTAssertEqual(results.first?.outcome, .selected)
        XCTAssertEqual(hardware.writes, [hardware.speakerUID])
        XCTAssertEqual(store.currentDeviceID, hardware.speaker.id)
        XCTAssertEqual(routes.preparedLeaves, 1)
        try await store.shutdown()
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), "Fixture did not reach the expected observable boundary.", file: file, line: line)
    }
}

@MainActor
private final class StoreInteractionBarrier {
    private var released = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { !pending.isEmpty }

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { pending.append($0) }
    }

    func release() {
        released = true
        let continuations = pending
        pending.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
private final class StoreInteractionTrace {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private final class StoreInteractionShutdownSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func close() { lock.withLock { calls += 1 } }
}

@MainActor
private final class StoreInteractionHardware: AudioHardwareProviding {
    let speakerUID = "BuiltInSpeakerDevice-fixture"
    let externalUID = "USB-output-complete-UID-fixture"
    let streamUID = "receiver-complete-stream-UID-Audio-fixture"
    let trace: StoreInteractionTrace
    nonisolated let shutdownSignal = StoreInteractionShutdownSignal()
    var speaker: AudioDevice {
        AudioDevice(id: "hal:\(speakerUID)", name: "Speakers", transport: .speaker,
                    backend: .coreAudio(uid: speakerUID), shortcutTarget: .hal(uid: speakerUID))
    }
    var external: AudioDevice {
        AudioDevice(id: "hal:\(externalUID)", name: "USB Output", transport: .usb,
                    backend: .coreAudio(uid: externalUID), shortcutTarget: .hal(uid: externalUID))
    }
    var stream: AudioDevice {
        AudioDevice(id: "hal:\(streamUID)", name: "AirPlay", transport: .airplay, backend: .coreAudio(uid: streamUID))
    }
    var current = "hal:BuiltInSpeakerDevice-fixture"
    var includeReceiver = false
    var speakerObject: UInt32 = 100
    var streamObject: UInt32 = 200
    var snapshotReads = 0
    var observationAttempts = 0
    var failObservation = false
    var holdObservation = false
    private var pendingObservation: CheckedContinuation<Void, Never>?
    var hasPendingObservation: Bool { pendingObservation != nil }
    private var changed: (@Sendable () -> Void)?
    var writes: [String] = []
    var pauseNextSelection = false
    private var pendingSelection: CheckedContinuation<Void, Never>?
    var hasPendingSelection: Bool { pendingSelection != nil }
    var pauseNextSnapshot = false
    private var pendingSnapshot: CheckedContinuation<Void, Never>?
    var hasPendingSnapshot: Bool { pendingSnapshot != nil }

    init(trace: StoreInteractionTrace) { self.trace = trace }

    nonisolated func beginShutdown() { shutdownSignal.close() }

    func snapshot() async throws -> CoreAudioSnapshot {
        snapshotReads += 1
        var objects: [String: UInt32] = [speakerUID: speakerObject, externalUID: 300]
        if includeReceiver { objects[streamUID] = streamObject }
        let captured = CoreAudioSnapshot(devices: [speaker, external] + (includeReceiver ? [stream] : []),
                                         currentDeviceID: current, systemSoundDeviceID: speaker.id,
                                         warnings: [], confirmedDeviceObjects: objects)
        if pauseNextSnapshot {
            pauseNextSnapshot = false
            await withCheckedContinuation { pendingSnapshot = $0 }
        }
        return captured
    }

    func resumeSnapshot() {
        let pending = pendingSnapshot
        pendingSnapshot = nil
        pending?.resume()
    }

    func builtInSpeaker() async throws -> AudioDevice { speaker }

    func select(uid: String) async throws {
        trace.append("select:\(uid)")
        writes.append(uid)
        if pauseNextSelection {
            pauseNextSelection = false
            // Deliberately outlives Task.cancel, like a registered native write.
            await withCheckedContinuation { pendingSelection = $0 }
        }
        current = "hal:\(uid)"
    }

    func resumeSelection() {
        let pending = pendingSelection
        pendingSelection = nil
        pending?.resume()
    }

    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws {
        observationAttempts += 1
        if failObservation { throw AudioServiceError.unavailable("injected listener failure") }
        if holdObservation { await withCheckedContinuation { pendingObservation = $0 } }
        self.changed = changed
    }
    func signalChange() { changed?() }
    func resumeObservation() {
        holdObservation = false
        let pending = pendingObservation
        pendingObservation = nil
        pending?.resume()
    }
    func stopObserving() async {}
}

@MainActor
private final class StoreInteractionRoutes: PrivateRouting {
    let receiverID = "receiver-complete-ID-fixture"
    let trace: StoreInteractionTrace
    var onChange: (() -> Void)?
    var periodicObservation: [Bool] = []
    var includeReceiver = false
    var ownershipReads = 0
    var preparedLeaves = 0
    var closed = false
    var shutdowns = 0
    var pauseNextFreshSnapshot = false
    var freshSnapshotReads = 0
    var freshSnapshotOverride: PrivateRouteSnapshot?
    var selections: [String] = []
    var onSelect: (() -> Void)?
    private var pendingFreshSnapshot: CheckedContinuation<Void, Never>?
    var hasPendingFreshSnapshot: Bool { pendingFreshSnapshot != nil }

    init(trace: StoreInteractionTrace) { self.trace = trace }
    func start() {}
    func setPeriodicObservation(_ active: Bool) { periodicObservation.append(active) }
    func stop() {}
    func beginShutdown() { closed = true }

    func snapshot() -> PrivateRouteSnapshot {
        guard includeReceiver else { return .init(routes: [], warning: nil, diagnostics: "interaction fixture") }
        let uid = "receiver-complete-stream-UID-Audio-fixture"
        let route = PrivateAudioRoute(identifier: receiverID, name: "Receiver", uid: uid,
                                      isSelected: true, canSelect: true, transport: "airplay")
        return .init(routes: [route], warning: nil, diagnostics: "strict receiver fixture",
                     selectedVolumeAssociation: .init(identifier: receiverID, uid: uid),
                     confirmedShortcutIdentifiers: [receiverID])
    }

    func freshSnapshot() async -> PrivateRouteSnapshot {
        freshSnapshotReads += 1
        let captured = freshSnapshotOverride ?? snapshot()
        if pauseNextFreshSnapshot {
            pauseNextFreshSnapshot = false
            await withCheckedContinuation { pendingFreshSnapshot = $0 }
        }
        return captured
    }

    func resumeFreshSnapshot() {
        let pending = pendingFreshSnapshot
        pendingFreshSnapshot = nil
        pending?.resume()
    }

    func select(identifier: String) async throws {
        selections.append(identifier)
        trace.append("privateSelect:\(identifier)")
        onSelect?()
    }
    func prepareToLeave() async throws { preparedLeaves += 1; trace.append("prepareLeave") }
    func completedLeave() async throws { trace.append("completeLeave") }
    func ownedStreamForExit() async throws -> OwnedRouteExitEvidence? {
        ownershipReads += 1
        trace.append("ownership")
        return .init(receiverID: receiverID, streamUID: "owned-complete-stream-UID-fixture", name: "Receiver")
    }
    func shutdown() async throws { shutdowns += 1 }
}
