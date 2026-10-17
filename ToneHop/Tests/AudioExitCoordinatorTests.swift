import CoreAudio
import XCTest
@testable import ToneHop

/// D exit policy exercised through its normal service protocols. These fixtures
/// never instantiate native audio services, submit HAL writes, or call Remove.
@MainActor
final class AudioExitCoordinatorTests: XCTestCase {
    func testPrepareOnlyReadsOwnedEvidenceAndRequiresConfirmation() async throws {
        let fixture = ExitCoordinatorFixture()
        let plan = try await fixture.coordinator.prepare()

        XCTAssertEqual(plan.ownedStream, ExitCoordinatorRoutes.original)
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertEqual(fixture.trace.events, ["owned:original-stream"])
        XCTAssertTrue(fixture.hardware.writes.isEmpty)
        XCTAssertEqual(fixture.routes.cleanupCalls, 0)
    }

    func testNoOwnedStreamNeverSelectsSpeakerOrRunsCleanup() async throws {
        let fixture = ExitCoordinatorFixture()
        fixture.routes.owned = nil
        let plan = try await fixture.coordinator.prepare()
        XCTAssertFalse(plan.requiresConfirmation)

        try await fixture.coordinator.complete(plan)

        XCTAssertEqual(fixture.trace.events, ["owned:none", "owned:none"])
        XCTAssertTrue(fixture.hardware.writes.isEmpty)
        XCTAssertEqual(fixture.routes.cleanupCalls, 0)
    }

    func testConfirmedExactStreamSelectsSpeakerVerifiesHALThenCleansAndConfirmsEmpty() async throws {
        let fixture = ExitCoordinatorFixture()
        let plan = try await fixture.coordinator.prepare()
        // A display-name change does not change the approved stream identity.
        fixture.routes.owned = OwnedRouteExitEvidence(receiverID: "receiver", streamUID: "original-stream", name: "Renamed")

        try await fixture.coordinator.complete(plan)

        XCTAssertEqual(fixture.trace.events, [
            "owned:original-stream", "owned:original-stream", "speaker", "owned:original-stream",
            "select:speaker", "hal:hal:speaker", "speaker", "completedLeave", "owned:none",
        ])
        XCTAssertEqual(fixture.hardware.writes, ["speaker"])
        XCTAssertEqual(fixture.routes.cleanupCalls, 1)
        XCTAssertNil(fixture.routes.owned)
    }

    func testNewStreamWithoutApprovalIsRejectedBeforeAnyWrite() async throws {
        let fixture = ExitCoordinatorFixture()
        await assertRejected(fixture.coordinator, plan: AudioExitPlan(ownedStream: nil), contains: expectedLocalized("The previous audio stream changed", "旧音频流已变化"))
        XCTAssertEqual(fixture.trace.events, ["owned:original-stream"])
        XCTAssertTrue(fixture.hardware.writes.isEmpty)
        XCTAssertEqual(fixture.routes.cleanupCalls, 0)
    }

    func testChangedReceiverOrStreamIsRejectedBeforeSpeakerDiscovery() async throws {
        for replacement in [
            OwnedRouteExitEvidence(receiverID: "receiver", streamUID: "replacement-stream", name: "Receiver"),
            OwnedRouteExitEvidence(receiverID: "replacement-receiver", streamUID: "original-stream", name: "Receiver"),
        ] {
            let fixture = ExitCoordinatorFixture()
            let plan = try await fixture.coordinator.prepare()
            fixture.trace.events.removeAll()
            fixture.routes.owned = replacement

            await assertRejected(fixture.coordinator, plan: plan, contains: expectedLocalized("The previous audio stream changed", "旧音频流已变化"))

            XCTAssertEqual(fixture.trace.events, ["owned:\(replacement.streamUID)"])
            XCTAssertTrue(fixture.hardware.writes.isEmpty)
            XCTAssertEqual(fixture.routes.cleanupCalls, 0)
        }
    }

    func testOwnershipIsRevalidatedAfterAsynchronousSpeakerDiscovery() async throws {
        let fixture = ExitCoordinatorFixture()
        let plan = try await fixture.coordinator.prepare()
        fixture.hardware.onSpeakerRead = { [routes = fixture.routes] in
            routes.owned = OwnedRouteExitEvidence(receiverID: "receiver", streamUID: "replacement-stream", name: "Receiver")
        }

        await assertRejected(fixture.coordinator, plan: plan, contains: expectedLocalized("The previous audio stream changed", "旧音频流已变化"))

        XCTAssertEqual(fixture.trace.events, ["owned:original-stream", "owned:original-stream", "speaker", "owned:replacement-stream"])
        XCTAssertTrue(fixture.hardware.writes.isEmpty)
        XCTAssertEqual(fixture.routes.cleanupCalls, 0)
    }

    func testStreamRemovedDuringSpeakerDiscoveryRequiresNoWrite() async throws {
        let fixture = ExitCoordinatorFixture()
        let plan = try await fixture.coordinator.prepare()
        fixture.hardware.onSpeakerRead = { [routes = fixture.routes] in routes.owned = nil }

        try await fixture.coordinator.complete(plan)

        XCTAssertTrue(fixture.hardware.writes.isEmpty)
        XCTAssertEqual(fixture.routes.cleanupCalls, 0)
        XCTAssertEqual(fixture.trace.events.last, "owned:none")
    }

    func testUnavailableSpeakerRejectsWithoutAnyWrite() async throws {
        for throwsOnDiscovery in [false, true] {
            let fixture = ExitCoordinatorFixture()
            fixture.hardware.speaker.isAvailable = false
            if throwsOnDiscovery { fixture.hardware.speakerError = AudioServiceError.unavailable("扬声器不可读") }
            let plan = try await fixture.coordinator.prepare()

            await assertRejected(fixture.coordinator, plan: plan, contains: throwsOnDiscovery ? "扬声器不可读" : expectedLocalized("The built-in Mac speakers could not be confirmed", "无法确认 Mac 自带扬声器"))

            XCTAssertTrue(fixture.hardware.writes.isEmpty)
            XCTAssertEqual(fixture.routes.cleanupCalls, 0)
        }
    }

    func testMismatchingHALReadbackTimesOutWithoutCallingRemove() async throws {
        let fixture = ExitCoordinatorFixture()
        fixture.hardware.selectChangesOutput = false
        let plan = try await fixture.coordinator.prepare()
        var coordinator = fixture.coordinator
        coordinator.readbackTimeout = .zero

        await assertRejected(coordinator, plan: plan, contains: expectedLocalized("The switch to the built-in Mac speakers could not be confirmed", "未能确认输出已切换"))

        XCTAssertEqual(fixture.hardware.writes, ["speaker"])
        XCTAssertEqual(fixture.routes.cleanupCalls, 0)
        XCTAssertEqual(fixture.routes.owned, ExitCoordinatorRoutes.original)
    }

    func testTransientDefaultReadAfterSwitchRetriesReadsWithoutRepeatingTheWrite() async throws {
        let fixture = ExitCoordinatorFixture()
        var reads = 0
        fixture.hardware.onSnapshot = { [hardware = fixture.hardware] in
            reads += 1
            hardware.snapshotError = reads == 1 ? AudioServiceError.system(operation: "fixture", status: kAudioHardwareBadObjectError) : nil
        }
        try await fixture.coordinator.complete(fixture.coordinator.prepare())
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(fixture.hardware.writes, ["speaker"])
        XCTAssertEqual(fixture.routes.cleanupCalls, 1)
    }

    func testTransientSpeakerRevalidationRetriesWithoutRepeatingTheWrite() async throws {
        for transient in [AudioServiceError.system(operation: "fixture", status: kAudioHardwareBadDeviceError) as any Error,
                          AudioHardwareReadFailure.unstableInventory] {
            let fixture = ExitCoordinatorFixture()
            var reads = 0
            fixture.hardware.onSpeakerRead = { [hardware = fixture.hardware] in
                reads += 1
                hardware.speakerError = reads == 2 ? transient : nil
            }
            try await fixture.coordinator.complete(fixture.coordinator.prepare())
            XCTAssertEqual(reads, 3)
            XCTAssertEqual(fixture.hardware.writes, ["speaker"])
            XCTAssertEqual(fixture.routes.cleanupCalls, 1)
        }
    }

    func testPersistentTransientReadHasDeadlineAndNeverCleansAnUnconfirmedOutput() async throws {
        let fixture = ExitCoordinatorFixture()
        fixture.hardware.snapshotError = AudioServiceError.system(operation: "fixture", status: kAudioHardwareBadObjectError)
        var coordinator = fixture.coordinator
        coordinator.readbackTimeout = .zero
        let plan = try await coordinator.prepare()
        await assertRejected(coordinator, plan: plan, contains: expectedLocalized("The switch to the built-in Mac speakers could not be confirmed", "未能确认输出已切换"))
        XCTAssertEqual(fixture.hardware.writes, ["speaker"])
        XCTAssertEqual(fixture.routes.cleanupCalls, 0)
    }

    func testNontransientReadErrorIsNotRetriedOrConvertedIntoSuccess() async throws {
        let fixture = ExitCoordinatorFixture()
        fixture.hardware.snapshotError = AudioServiceError.system(operation: "不支持的属性", status: kAudioHardwareUnknownPropertyError)
        let plan = try await fixture.coordinator.prepare()
        await assertRejected(fixture.coordinator, plan: plan, contains: "不支持的属性")
        XCTAssertEqual(fixture.trace.events.filter { $0.hasPrefix("hal:") }.count, 1)
        XCTAssertEqual(fixture.hardware.writes, ["speaker"])
        XCTAssertEqual(fixture.routes.cleanupCalls, 0)
    }

    func testSpeakerIdentityChangeAfterHALReadbackRejectsCleanup() async throws {
        let fixture = ExitCoordinatorFixture()
        let plan = try await fixture.coordinator.prepare()
        fixture.hardware.onSnapshot = { [weak hardware = fixture.hardware] in
            hardware?.speaker = AudioDevice(id: "hal:replacement-speaker", name: "Speakers", transport: .speaker,
                                           backend: .coreAudio(uid: "replacement-speaker"))
        }

        await assertRejected(fixture.coordinator, plan: plan, contains: expectedLocalized("The built-in Mac speakers changed state", "扬声器状态已变化"))

        XCTAssertEqual(fixture.hardware.writes, ["speaker"])
        XCTAssertEqual(fixture.routes.cleanupCalls, 0)
    }

    func testRemoveFailurePropagatesAndDoesNotPretendTheStreamWasRemoved() async throws {
        let fixture = ExitCoordinatorFixture()
        fixture.routes.cleanupError = AudioServiceError.unavailable("精确 Remove 失败")
        let plan = try await fixture.coordinator.prepare()

        await assertRejected(fixture.coordinator, plan: plan, contains: "精确 Remove 失败")

        XCTAssertEqual(fixture.routes.cleanupCalls, 1)
        XCTAssertEqual(fixture.routes.owned, ExitCoordinatorRoutes.original)
        XCTAssertEqual(fixture.trace.events.last, "completedLeave")
        XCTAssertFalse(fixture.trace.events.contains("owned:none"))
    }

    func testCleanupReturningWithoutEmptyReadbackCannotCompleteExit() async throws {
        let fixture = ExitCoordinatorFixture()
        fixture.routes.cleanupRemovesStream = false
        let plan = try await fixture.coordinator.prepare()

        await assertRejected(fixture.coordinator, plan: plan, contains: expectedLocalized("Cleanup of the previous audio stream is not yet confirmed", "旧音频流尚未确认清理完成"))

        XCTAssertEqual(fixture.routes.cleanupCalls, 1)
        XCTAssertEqual(fixture.trace.events.last, "owned:original-stream")
    }

    func testReplacementStreamAppearingDuringCleanupCannotCompleteExit() async throws {
        let fixture = ExitCoordinatorFixture()
        fixture.routes.cleanupRemovesStream = false
        fixture.routes.onCleanup = { [weak routes = fixture.routes] in
            routes?.owned = OwnedRouteExitEvidence(receiverID: "receiver", streamUID: "replacement-stream", name: "Receiver")
        }
        let plan = try await fixture.coordinator.prepare()

        await assertRejected(fixture.coordinator, plan: plan, contains: expectedLocalized("Cleanup of the previous audio stream is not yet confirmed", "旧音频流尚未确认清理完成"))

        XCTAssertEqual(fixture.routes.cleanupCalls, 1)
        XCTAssertEqual(fixture.trace.events.last, "owned:replacement-stream")
    }

    func testExternalOutputChangeDuringCleanupKeepsTheServiceRefusal() async throws {
        let fixture = ExitCoordinatorFixture()
        fixture.routes.onCleanup = { [weak hardware = fixture.hardware, weak routes = fixture.routes] in
            hardware?.currentID = "hal:external-stream"
            routes?.cleanupError = AudioServiceError.unavailable("系统已切换到其他输出，拒绝清理旧流")
        }
        let plan = try await fixture.coordinator.prepare()

        await assertRejected(fixture.coordinator, plan: plan, contains: "系统已切换到其他输出")

        XCTAssertEqual(fixture.routes.cleanupCalls, 1)
        XCTAssertEqual(fixture.routes.owned, ExitCoordinatorRoutes.original)
        XCTAssertFalse(fixture.trace.events.contains("owned:none"))
    }

    private func assertRejected(_ coordinator: AudioExitCoordinator, plan: AudioExitPlan, contains message: String,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await coordinator.complete(plan)
            XCTFail("Exit must remain unconfirmed", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription, file: file, line: line)
        }
    }
}

@MainActor
private final class ExitCoordinatorTrace {
    var events: [String] = []
}

@MainActor
private final class ExitCoordinatorFixture {
    let trace = ExitCoordinatorTrace()
    let hardware: ExitCoordinatorHardware
    let routes: ExitCoordinatorRoutes
    var coordinator: AudioExitCoordinator { AudioExitCoordinator(hardware: hardware, routes: routes) }

    init() {
        hardware = ExitCoordinatorHardware(trace: trace)
        routes = ExitCoordinatorRoutes(trace: trace)
    }
}

@MainActor
private final class ExitCoordinatorHardware: AudioHardwareProviding {
    let trace: ExitCoordinatorTrace
    var speaker = AudioDevice(id: "hal:speaker", name: "Speakers", transport: .speaker, backend: .coreAudio(uid: "speaker"))
    var currentID = "hal:original-stream"
    var writes: [String] = []
    var selectChangesOutput = true
    var speakerError: (any Error)?
    var snapshotError: (any Error)?
    var onSpeakerRead: (() -> Void)?
    var onSnapshot: (() -> Void)?

    init(trace: ExitCoordinatorTrace) { self.trace = trace }
    nonisolated func beginShutdown() {}
    func snapshot() async throws -> CoreAudioSnapshot {
        trace.events.append("hal:\(currentID)")
        let snapshot = CoreAudioSnapshot(devices: [speaker], currentDeviceID: currentID,
                                         systemSoundDeviceID: nil, warnings: [])
        onSnapshot?()
        if let snapshotError { throw snapshotError }
        return snapshot
    }
    func builtInSpeaker() async throws -> AudioDevice {
        trace.events.append("speaker")
        onSpeakerRead?()
        if let speakerError { throw speakerError }
        return speaker
    }
    func select(uid: String) async throws {
        trace.events.append("select:\(uid)")
        writes.append(uid)
        if selectChangesOutput { currentID = "hal:\(uid)" }
    }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws {}
    func stopObserving() async {}
}

@MainActor
private final class ExitCoordinatorRoutes: PrivateRouting {
    static let original = OwnedRouteExitEvidence(receiverID: "receiver", streamUID: "original-stream", name: "Receiver")
    let trace: ExitCoordinatorTrace
    var onChange: (() -> Void)?
    var owned: OwnedRouteExitEvidence? = original
    var cleanupCalls = 0
    var cleanupRemovesStream = true
    var cleanupError: (any Error)?
    var onCleanup: (() -> Void)?

    init(trace: ExitCoordinatorTrace) { self.trace = trace }
    func start() {}
    func stop() {}
    func beginShutdown() {}
    func snapshot() -> PrivateRouteSnapshot { .init(routes: [], warning: nil, diagnostics: "exit fixture") }
    func select(identifier: String) async throws { XCTFail("Exit must not request a receiver selection") }
    func prepareToLeave() async throws { XCTFail("Exit uses the approved owned-stream evidence") }
    func ownedStreamForExit() async throws -> OwnedRouteExitEvidence? {
        trace.events.append("owned:\(owned?.streamUID ?? "none")")
        return owned
    }
    func completedLeave() async throws {
        trace.events.append("completedLeave")
        cleanupCalls += 1
        onCleanup?()
        if let cleanupError { throw cleanupError }
        if cleanupRemovesStream { owned = nil }
    }
}
