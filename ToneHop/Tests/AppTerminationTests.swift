import AppKit
import XCTest
@testable import ToneHop

/// Calls the real delegate entry. Dependencies never display UI, write audio,
/// or reply to NSApplication, so the hosted XCTest process remains running.
@MainActor
final class AppTerminationTests: XCTestCase {
    func testRepeatedTerminationRequestsShareOnePendingConfirmationAndCleanup() async {
        let fixture = TerminationFixture()
        fixture.suspendConfirmation = true
        let application = NSApplication.shared

        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(application), .terminateLater)
        await waitUntil { fixture.confirmations == 1 }
        for _ in 0..<4 {
            XCTAssertEqual(fixture.delegate.applicationShouldTerminate(application), .terminateLater)
        }
        XCTAssertEqual(fixture.confirmations, 1)
        XCTAssertTrue(fixture.replies.isEmpty)
        XCTAssertTrue(fixture.hardware.writes.isEmpty)
        XCTAssertEqual(fixture.routes.cleanups, 0)

        fixture.answerConfirmation(true)
        await waitUntil { fixture.replies == [true] }

        XCTAssertEqual(fixture.hardware.writes, ["speaker"])
        XCTAssertEqual(fixture.routes.cleanups, 1)
        XCTAssertEqual(fixture.routes.shutdowns, 1)
        XCTAssertEqual(fixture.hardware.stops, 1)
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(application), .terminateNow)
        XCTAssertEqual(fixture.replies, [true], "A completed request must not receive a second reply.")
    }

    func testCancelledConfirmationRepliesFalseWithoutSideEffectsAndCanQuitAgain() async {
        let fixture = TerminationFixture()
        fixture.confirmAnswer = false
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(.shared), .terminateLater)
        await waitUntil { fixture.replies == [false] }

        XCTAssertFalse(fixture.store.isPreparingToQuit)
        XCTAssertTrue(fixture.hardware.writes.isEmpty)
        XCTAssertEqual(fixture.routes.cleanups, 0)
        XCTAssertEqual(fixture.routes.shutdowns, 0)
        XCTAssertEqual(fixture.hardware.stops, 0)

        fixture.confirmAnswer = true
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(.shared), .terminateLater)
        await waitUntil { fixture.replies == [false, true] }
        XCTAssertEqual(fixture.confirmations, 2)
        XCTAssertEqual(fixture.routes.cleanups, 1)
        XCTAssertEqual(fixture.routes.shutdowns, 1)
    }

    func testNoOwnedStreamPreservesOriginalTerminationHandshakeAndDoesNotAskOrSwitch() async {
        let fixture = TerminationFixture()
        fixture.routes.owned = nil
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(.shared), .terminateLater)
        await waitUntil { fixture.replies == [true] }

        XCTAssertEqual(fixture.confirmations, 0)
        XCTAssertTrue(fixture.hardware.writes.isEmpty)
        XCTAssertEqual(fixture.routes.cleanups, 0)
        XCTAssertEqual(fixture.routes.shutdowns, 1)
        XCTAssertEqual(fixture.hardware.stops, 1)
        XCTAssertTrue(fixture.failures.isEmpty)
    }

    func testCleanupFailureRepliesFalseKeepsServicesOpenAndAllowsAConfirmedRetry() async {
        let fixture = TerminationFixture()
        fixture.routes.failCleanup = true
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(.shared), .terminateLater)
        await waitUntil { fixture.replies == [false] }

        XCTAssertEqual(fixture.failures.count, 1)
        XCTAssertNotEqual(fixture.store.feedbackKind, .failure)
        XCTAssertFalse(fixture.store.feedback.contains("Fixture"))
        XCTAssertFalse(fixture.store.isPreparingToQuit)
        XCTAssertEqual(fixture.routes.shutdowns, 0)
        XCTAssertEqual(fixture.hardware.stops, 0)
        XCTAssertEqual(fixture.routes.cleanups, 1)
        XCTAssertNotNil(fixture.routes.owned)

        fixture.routes.failCleanup = false
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(.shared), .terminateLater)
        await waitUntil { fixture.replies == [false, true] }
        XCTAssertEqual(fixture.confirmations, 2)
        XCTAssertEqual(fixture.routes.cleanups, 2)
        XCTAssertEqual(fixture.routes.shutdowns, 1)
    }

    func testPreflightFailureRepliesFalseWithoutConfirmationAndCanRetry() async {
        let fixture = TerminationFixture()
        fixture.routes.failPreflight = true
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(.shared), .terminateLater)
        await waitUntil { fixture.replies == [false] }

        XCTAssertEqual(fixture.confirmations, 0)
        XCTAssertEqual(fixture.failures.count, 1)
        XCTAssertNotEqual(fixture.store.feedbackKind, .failure)
        XCTAssertFalse(fixture.store.feedback.contains("Fixture"))
        XCTAssertTrue(fixture.hardware.writes.isEmpty)
        XCTAssertEqual(fixture.routes.shutdowns, 0)
        fixture.routes.failPreflight = false
        XCTAssertEqual(fixture.delegate.applicationShouldTerminate(.shared), .terminateLater)
        await waitUntil { fixture.replies == [false, true] }
        XCTAssertEqual(fixture.confirmations, 1)
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
}

@MainActor
private final class TerminationFixture {
    let hardware = TerminationHardware()
    let routes = TerminationRoutes()
    let store: AudioStore
    var confirmations = 0
    var confirmAnswer = true
    var suspendConfirmation = false
    private var confirmation: CheckedContinuation<Bool, Never>?
    var replies: [Bool] = []
    var failures: [String] = []

    lazy var delegate = AppDelegate(
        store: store,
        confirm: { [weak self] _ in
            guard let self else { return false }
            confirmations += 1
            if suspendConfirmation {
                return await withCheckedContinuation { confirmation = $0 }
            }
            return confirmAnswer
        },
        recordFailure: { [weak self] in self?.failures.append($0.localizedDescription) },
        reply: { [weak self] _, answer in self?.replies.append(answer) }
    )

    init() { store = AudioStore(hardware: hardware, routes: routes) }

    func answerConfirmation(_ answer: Bool) {
        let pending = confirmation
        confirmation = nil
        pending?.resume(returning: answer)
    }
}

@MainActor
private final class TerminationHardware: AudioHardwareProviding {
    let speaker = AudioDevice(id: "hal:speaker", name: "Fixture speaker", transport: .speaker, backend: .coreAudio(uid: "speaker"))
    var currentID = "hal:owned-stream"
    var writes: [String] = []
    var stops = 0
    nonisolated func beginShutdown() {}
    func snapshot() async throws -> CoreAudioSnapshot {
        CoreAudioSnapshot(devices: [speaker], currentDeviceID: currentID, systemSoundDeviceID: nil, warnings: [])
    }
    func builtInSpeaker() async throws -> AudioDevice { speaker }
    func select(uid: String) async throws { writes.append(uid); currentID = "hal:\(uid)" }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws {}
    func stopObserving() async { stops += 1 }
}

@MainActor
private final class TerminationRoutes: PrivateRouting {
    var onChange: (() -> Void)?
    var owned: OwnedRouteExitEvidence? = .init(receiverID: "receiver", streamUID: "owned-stream", name: "Receiver")
    var cleanups = 0
    var shutdowns = 0
    var failPreflight = false
    var failCleanup = false
    func start() {}
    func stop() {}
    func beginShutdown() {}
    func snapshot() -> PrivateRouteSnapshot { .init(routes: [], warning: nil, diagnostics: "termination fixture") }
    func select(identifier: String) async throws { XCTFail("Termination must not select another receiver") }
    func prepareToLeave() async throws { XCTFail("Termination uses explicit owned-stream evidence") }
    func ownedStreamForExit() async throws -> OwnedRouteExitEvidence? {
        if failPreflight { throw AudioServiceError.unavailable("Fixture preflight failure") }
        return owned
    }
    func completedLeave() async throws {
        cleanups += 1
        if failCleanup { throw AudioServiceError.unavailable("Fixture cleanup failure") }
        owned = nil
    }
    func shutdown() async throws { shutdowns += 1 }
}
