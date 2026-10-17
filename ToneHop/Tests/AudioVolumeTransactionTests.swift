import Foundation
import XCTest
@testable import ToneHop

@MainActor
final class AudioVolumeTransactionTests: XCTestCase {
    private let target = AudioVolumeTarget(deviceID: "hal:test-output", uid: "test-output")

    func testPositiveVolumeIsReadBackBeforeUnmutingAndMuteIsReadBackAfterward() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2, mute: .muted, canUnmute: true),
            .init(value: 0.6, mute: .muted, canUnmute: true),
            .init(value: 0.6, mute: .muted, canUnmute: true),
            .init(value: 0.6, mute: .unmuted, canUnmute: true),
        ])

        let result = try await run(0.6, access: access)
        let events = await access.recordedEvents()

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.value, 0.6)
        XCTAssertEqual(result.snapshot.mute, .unmuted)
        XCTAssertEqual(events, [
            .read(0.2, .muted), .volume(0.6),
            .read(0.6, .muted), .read(0.6, .muted),
            .unmuteAttempt(0.6), .unmute(0.6), .read(0.6, .unmuted),
        ])
    }

    func testZeroChangesOnlyScalarAndDoesNotWriteMute() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.6, mute: .unmuted, canUnmute: true),
            .init(value: 0, mute: .unmuted, canUnmute: true),
        ])

        let result = try await run(0, access: access)
        let events = await access.recordedEvents()

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.value, 0)
        XCTAssertEqual(result.snapshot.mute, .unmuted)
        XCTAssertEqual(events, [.read(0.6, .unmuted), .volume(0), .read(0, .unmuted)])
    }

    func testUnknownMuteIsReportedWithoutGuessingAnUnmute() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2, mute: .unknown),
            .init(value: 0.6, mute: .unknown),
        ])

        let result = try await run(0.6, access: access)

        XCTAssertEqual(result.issue, .muteUnknown)
        XCTAssertEqual(result.snapshot.value, 0.6)
        XCTAssertEqual(result.snapshot.mute, .unknown)
        await assertNoUnmute(access)
    }

    func testReadOnlyMutePreservesConfirmedVolumeAndReportsStillMuted() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2, mute: .muted, canUnmute: false),
            .init(value: 0.6, mute: .muted, canUnmute: false),
        ])

        let result = try await run(0.6, access: access)

        XCTAssertEqual(result.issue, .stillMuted)
        XCTAssertEqual(result.snapshot.value, 0.6)
        XCTAssertEqual(result.snapshot.mute, .muted)
        await assertNoUnmute(access)
    }

    func testMixedMuteWithoutUnifiedWritableControlIsNotReportedAsUnmuted() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2, mute: .mixed, canUnmute: false),
            .init(value: 0.6, mute: .mixed, canUnmute: false),
        ])

        let result = try await run(0.6, access: access)

        XCTAssertEqual(result.issue, .stillMuted)
        XCTAssertEqual(result.snapshot.mute, .mixed)
        await assertNoUnmute(access)
    }

    func testReadOnlyVolumeRejectsBothMutations() async {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2, capability: .unavailable(.readOnly), mute: .muted, canUnmute: true),
        ])

        do {
            _ = try await run(0.6, access: access)
            XCTFail("A read-only volume must reject the request.")
        } catch {
            XCTAssertEqual(error as? AudioVolumeIssue, .readOnly)
        }
        let events = await access.recordedEvents()
        XCTAssertEqual(events, [.read(0.2, .muted)])
    }

    func testAcceptedSetterWithoutAnyReadbackChangeRemainsUnconfirmed() async throws {
        let access = VolumeTransactionFixture(states: [.init(value: 0.2)])

        let result = try await run(0.6, access: access, timeout: .zero)

        XCTAssertEqual(result.issue, .unconfirmed)
        XCTAssertEqual(result.snapshot.value, 0.2)
        await assertNoUnmute(access)
    }

    func testStableMovementInRequestedDirectionDoesNotProveRequestedVolume() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2),
            .init(value: 0.25),
        ])

        // Repeated observations deliberately defeat the former "two stable
        // values in the requested direction" confirmation heuristic.
        let result = try await run(0.8, access: access, timeout: .milliseconds(100))
        let events = await access.recordedEvents()
        let repeated = events.filter { $0 == .read(0.25, .unmuted) }

        XCTAssertGreaterThanOrEqual(repeated.count, 2)
        XCTAssertEqual(result.issue, .unconfirmed)
        XCTAssertEqual(result.snapshot.value, 0.25)
        await assertNoUnmute(access)
    }

    func testQuantizedMismatchRetainsActualValueWithoutClaimingGenericQuantizationSupport() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2),
            .init(value: 0.4375),
        ])

        // This records the current compatibility boundary; it is not evidence
        // that generic quantization support or the corresponding requirement is complete.
        let result = try await run(0.44, access: access, timeout: .zero)

        XCTAssertEqual(result.issue, .unconfirmed)
        XCTAssertEqual(result.snapshot.value, 0.4375)
        await assertNoUnmute(access)
    }

    func testEquivalentTargetUsesActualScalarAndDecibelsWhileSubmittingOriginalRequest() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2), .init(value: 0.4375, decibels: -10),
        ], equivalentTarget: equivalentTarget())

        let result = try await run(0.44, access: access, timeout: .zero)
        let events = await access.recordedEvents()

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.value, 0.4375)
        XCTAssertEqual(events.filter { if case .volume = $0 { return true }; return false }, [.volume(0.44)])
        await assertNoUnmute(access)
    }

    func testEquivalentScalarAloneCannotConfirmRequestedVolume() async throws {
        let decibelValues: [Float?] = [nil, -11]
        for decibels in decibelValues {
            let access = VolumeTransactionFixture(states: [
                .init(value: 0.2), .init(value: 0.4375, decibels: decibels),
            ], equivalentTarget: equivalentTarget())

            let result = try await run(0.44, access: access, timeout: .zero)

            XCTAssertEqual(result.issue, .unconfirmed)
            await assertNoUnmute(access)
        }
    }

    func testConfirmedEquivalentTargetCannotUnmuteAfterExternalDecibelChange() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2, mute: .muted, canUnmute: true),
            .init(value: 0.4375, mute: .muted, canUnmute: true, decibels: -10),
            .init(value: 0.4375, mute: .muted, canUnmute: true, decibels: -11),
        ], equivalentTarget: equivalentTarget())

        let result = try await run(0.44, access: access)

        XCTAssertEqual(result.issue, .unconfirmed)
        await assertNoUnmute(access)
    }

    func testConfirmedEquivalentTargetThatDriftsAfterUnmuteDoesNotEnterRecovery() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2, mute: .muted, canUnmute: true),
            .init(value: 0.4375, mute: .muted, canUnmute: true, decibels: -10),
        ], afterUnmute: [.init(value: 0.4375, decibels: -11)], equivalentTarget: equivalentTarget())

        let result = try await run(0.44, access: access)
        let events = await access.recordedEvents()

        XCTAssertEqual(result.issue, .unconfirmed)
        XCTAssertEqual(events.filter { $0 == .volume(0.44) }.count, 1)
        XCTAssertEqual(events.filter { $0 == .unmute(0.44) }.count, 1)
    }

    func testUnconfirmedMutedRequestUsesOneRecoveryWriteAndJointEquivalentReadback() async throws {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)],
            afterUnmute: [.init(value: 0.75, decibels: -2)], afterRecovery: [.init(value: 0.4375, decibels: -10)],
            equivalentTarget: equivalentTarget())

        let result = try await run(0.44, access: access, timeout: .zero)
        let events = await access.recordedEvents()

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.value, 0.4375)
        XCTAssertEqual(events.filter { $0 == .volume(0.44) }.count, 2)
        XCTAssertEqual(events.filter { $0 == .unmute(0.44) }.count, 1)
    }

    func testExternalChangeAfterConfirmationStopsUnmute() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2, mute: .muted, canUnmute: true),
            .init(value: 0.1, mute: .muted, canUnmute: true),
            .init(value: 0.8, mute: .muted, canUnmute: true),
        ])

        let result = try await run(0.1, access: access)

        XCTAssertEqual(result.issue, .unconfirmed)
        XCTAssertEqual(result.snapshot.value, 0.8)
        await assertNoUnmute(access)
    }

    func testExternalChangeWhileReadingBackUnmuteDoesNotReportVolumeSuccess() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2, mute: .muted, canUnmute: true),
            .init(value: 0.1, mute: .muted, canUnmute: true),
            .init(value: 0.1, mute: .muted, canUnmute: true),
            .init(value: 0.8, mute: .unmuted, canUnmute: true),
        ])

        let result = try await run(0.1, access: access)

        XCTAssertEqual(result.issue, .unconfirmed)
        XCTAssertEqual(result.snapshot.value, 0.8)
        XCTAssertEqual(result.snapshot.mute, .unmuted)
    }

    func testPermitCancelledAfterVolumeRejectsLaterUnmuteRegistration() async {
        let permit = AudioMutationPermit()
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2, mute: .muted, canUnmute: true),
            .init(value: 0.6, mute: .muted, canUnmute: true),
        ], cancelPermitAfterVolume: true)

        do {
            _ = try await run(0.6, access: access, permit: permit)
            XCTFail("Cancelling a request permit must reject its later mutation.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let events = await access.recordedEvents()
        XCTAssertTrue(events.contains(.volume(0.6)), "The first, already registered write remains real.")
        XCTAssertTrue(events.contains(.unmuteAttempt(0.6)))
        XCTAssertTrue(events.contains(.rejected))
        XCTAssertFalse(events.contains(.unmute(0.6)))
    }

    func testObjectReplacementAfterSubmissionRejectsReadbackAndUnmute() async {
        let access = VolumeTransactionFixture(states: [
            .init(objectID: 41, value: 0.2, mute: .muted, canUnmute: true),
            .init(objectID: 42, value: 0.6, mute: .muted, canUnmute: true),
        ])

        do {
            _ = try await run(0.6, access: access)
            XCTFail("A replacement object cannot confirm the original object's write.")
        } catch {
            XCTAssertEqual(error as? AudioVolumeIssue, .identityChanged)
        }
        await assertNoUnmute(access)
    }

    func testTinyNonzeroReadbackDoesNotConfirmExactZeroRequest() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0.2), .init(value: Float.leastNonzeroMagnitude),
        ])

        let result = try await run(0, access: access, timeout: .zero)

        XCTAssertEqual(result.issue, .unconfirmed)
        XCTAssertEqual(result.snapshot.value, Float.leastNonzeroMagnitude)
    }

    func testAbsoluteEpsilonNearZeroCannotHideRelativeMismatch() async throws {
        let requested: Float = 0.000001
        let actual: Float = 0.0000012
        let access = VolumeTransactionFixture(states: [.init(value: 0.2), .init(value: actual)])

        let result = try await run(requested, access: access, timeout: .zero)

        XCTAssertEqual(result.issue, .unconfirmed)
        XCTAssertEqual(result.snapshot.value, actual)
    }

    func testOneULPReadbackDifferenceIsOnlyNumericalTolerance() async throws {
        let requested: Float = 0.6
        let actual = requested.nextDown
        let access = VolumeTransactionFixture(states: [.init(value: 0.2), .init(value: actual)])

        let result = try await run(requested, access: access)

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.value, actual)
        await assertNoUnmute(access)
    }

    func testMutedIgnoredWriteUnmutesThenWritesOnceAfterActualUnmutedReadback() async throws {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)],
            afterUnmute: [.init(value: 0.6875)], afterRecovery: [.init(value: 0.65)])

        let result = try await run(0.65, access: access, timeout: .zero)
        let events = await access.recordedEvents()

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.value, 0.65)
        XCTAssertEqual(result.snapshot.mute, .unmuted)
        XCTAssertEqual(events, [
            .read(0, .muted), .volume(0.65), .read(0, .muted), .read(0, .muted),
            .unmuteAttempt(0.65), .unmute(0.65), .read(0.6875, .unmuted),
            .volume(0.65), .read(0.65, .unmuted)
        ])
    }

    func testMutedZeroReadbackDoesNotCertifyHiddenRestoreVolumeWasCleared() async throws {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)])

        let result = try await run(0, access: access, timeout: .zero)

        XCTAssertEqual(result.issue, .mutedVolumeUnconfirmed)
        XCTAssertEqual(result.snapshot.value, 0)
        let events = await access.recordedEvents()
        XCTAssertEqual(events, [.read(0, .muted), .volume(0), .read(0, .muted)])
    }

    func testMuteSetterNoErrButStillMutedDoesNotAuthorizeRecoveryVolume() async throws {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)])

        let result = try await run(0.65, access: access, timeout: .zero)
        let events = await access.recordedEvents()

        XCTAssertEqual(result.issue, .mutedVolumeUnconfirmed)
        XCTAssertEqual(events.filter { $0 == .volume(0.65) }.count, 1)
        XCTAssertEqual(events.filter { $0 == .unmute(0.65) }.count, 1)
    }

    func testZeroReadbackWithUnknownMuteDoesNotCertifyHiddenRestoreVolumeWasCleared() async throws {
        let access = VolumeTransactionFixture(states: [
            .init(value: 0, mute: .muted, canUnmute: true), .init(value: 0, mute: .unknown)
        ])

        let result = try await run(0, access: access, timeout: .zero)
        let events = await access.recordedEvents()

        XCTAssertEqual(result.issue, .unconfirmed)
        XCTAssertEqual(result.snapshot.mute, .unknown)
        XCTAssertEqual(events, [.read(0, .muted), .volume(0), .read(0, .unknown)])
    }

    func testDelayedUnmuteIsObservedBeforeSingleRecoveryWrite() async throws {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)],
            afterUnmute: [.init(value: 0, mute: .muted, canUnmute: true),
                          .init(value: 0, mute: .mixed, canUnmute: true), .init(value: 0.8)],
            afterRecovery: [.init(value: 0.65)])

        let result = try await run(0.65, access: access, timeout: .milliseconds(10))
        let events = await access.recordedEvents()

        XCTAssertNil(result.issue)
        XCTAssertEqual(events.filter { $0 == .volume(0.65) }.count, 2)
        let unmute = try XCTUnwrap(events.firstIndex(of: .unmute(0.65)))
        XCTAssertEqual(Array(events[(unmute + 1)...]), [
            .read(0, .muted), .read(0, .mixed), .read(0.8, .unmuted),
            .volume(0.65), .read(0.65, .unmuted)
        ])
    }

    func testUnknownMuteAfterAcceptedUnmuteStopsRecovery() async throws {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)],
            afterUnmute: [.init(value: 0, mute: .unknown)])

        let result = try await run(0.65, access: access, timeout: .zero)
        let events = await access.recordedEvents()

        XCTAssertEqual(result.issue, .unconfirmed)
        XCTAssertEqual(result.snapshot.mute, .unknown)
        XCTAssertEqual(events.filter { $0 == .volume(0.65) }.count, 1)
    }

    func testUnmuteFailureThatActuallyTookEffectDoesNotRetryVolume() async throws {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)],
            afterUnmute: [.init(value: 0.6875)], unmuteFailure: .writeFailed(-24))

        let result = try await run(0.65, access: access, timeout: .zero)
        let events = await access.recordedEvents()

        XCTAssertEqual(result.issue, .unmutedVolumeUnconfirmed)
        XCTAssertEqual(result.snapshot.value, 0.6875)
        XCTAssertEqual(result.snapshot.mute, .unmuted)
        XCTAssertEqual(events.filter { $0 == .volume(0.65) }.count, 1)
    }

    func testFirstVolumeFailureStopsBeforeAnyUnmuteOrRecovery() async {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)],
            volumeFailure: .writeFailed(-25))

        do {
            _ = try await run(0.65, access: access, timeout: .zero)
            XCTFail("A failed first setter cannot admit unmute recovery.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .writeFailed(-25)) }
        await assertNoUnmute(access)
        let events = await access.recordedEvents()
        XCTAssertEqual(events.filter { $0 == .volume(0.65) }.count, 1)
    }

    func testCancellationAfterUnmuteRejectsRecoveryWithoutRemuting() async {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)],
            afterUnmute: [.init(value: 0.8)], cancelPermitAfterUnmute: true)

        do {
            _ = try await run(0.65, access: access, timeout: .zero)
            XCTFail("An already admitted unmute cannot override later cancellation.")
        } catch { XCTAssertTrue(error is CancellationError) }
        let events = await access.recordedEvents()
        XCTAssertEqual(events.filter { $0 == .volume(0.65) }.count, 1)
        XCTAssertEqual(events.filter { $0 == .unmute(0.65) }.count, 1)
        XCTAssertTrue(events.contains(.rejected))
    }

    func testObjectReplacementAfterUnmuteRejectsRecovery() async {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)],
            afterUnmute: [.init(objectID: 42, value: 0.8)])

        do {
            _ = try await run(0.65, access: access, timeout: .zero)
            XCTFail("Recovery must not write a replacement object.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .identityChanged) }
        let events = await access.recordedEvents()
        XCTAssertEqual(events.filter { $0 == .volume(0.65) }.count, 1)
    }

    func testRecoveryMismatchIsReportedOnceWithoutRelaxingNumericalTolerance() async throws {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)],
            afterUnmute: [.init(value: 0.8)], afterRecovery: [.init(value: 0.64)])

        let result = try await run(0.65, access: access, timeout: .zero)
        let events = await access.recordedEvents()

        XCTAssertEqual(result.issue, .unmutedVolumeUnconfirmed)
        XCTAssertEqual(result.snapshot.value, 0.64)
        XCTAssertEqual(events.filter { $0 == .volume(0.65) }.count, 2)
        XCTAssertEqual(events.filter { $0 == .unmute(0.65) }.count, 1)
    }

    func testUnmuteThatRestoresRequestedValueDoesNotNeedRecoveryWrite() async throws {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)],
            afterUnmute: [.init(value: 0.65)])

        let result = try await run(0.65, access: access, timeout: .zero)
        let events = await access.recordedEvents()

        XCTAssertNil(result.issue)
        XCTAssertEqual(events.filter { $0 == .volume(0.65) }.count, 1)
    }

    func testReadOnlyOrUnknownMuteWithUnconfirmedValueCannotStartRecovery() async throws {
        for mute in [AudioVolumeMuteState.muted, .mixed, .unknown] {
            let access = VolumeTransactionFixture(states: [.init(value: 0, mute: mute, canUnmute: false)])
            let result = try await run(0.65, access: access, timeout: .zero)
            XCTAssertNotNil(result.issue)
            await assertNoUnmute(access)
        }
    }

    func testRecoveryWriteFailureDoesNotLoopBackToUnmute() async {
        let access = VolumeTransactionFixture(states: [.init(value: 0, mute: .muted, canUnmute: true)],
            afterUnmute: [.init(value: 0.8)], recoveryFailure: .writeFailed(-26))

        do {
            _ = try await run(0.65, access: access, timeout: .zero)
            XCTFail("The only recovery write failed.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .writeFailed(-26)) }
        let events = await access.recordedEvents()
        XCTAssertEqual(events.filter { $0 == .volume(0.65) }.count, 2)
        XCTAssertEqual(events.filter { $0 == .unmute(0.65) }.count, 1)
    }

    private func equivalentTarget() -> AudioVolumeEquivalentTarget {
        .init(scalar: 0.4375, decibels: -10, range: .init(minimum: -80, maximum: 0))
    }

    private func run(_ value: Float, access: VolumeTransactionFixture,
                     permit: AudioMutationPermit = AudioMutationPermit(),
                     timeout: Duration = .milliseconds(100)) async throws -> AudioVolumeWriteResult {
        try await AudioVolumeTransaction.run(value: value, target: target, permit: permit,
                                             access: access, timeout: timeout, interval: .milliseconds(1))
    }

    private func assertNoUnmute(_ access: VolumeTransactionFixture,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let events = await access.recordedEvents()
        XCTAssertFalse(events.contains(where: {
            if case .unmuteAttempt = $0 { return true }
            if case .unmute = $0 { return true }
            return false
        }), "No mute write should even be requested.", file: file, line: line)
    }
}

/// This actor supplies observations and records admitted mutations. It never
/// imports CoreAudio, owns native devices, or starts the application.
private actor VolumeTransactionFixture: AudioVolumeTransactionAccess {
    struct State: Sendable {
        let objectID: UInt32
        let value: Float?
        let capability: AudioVolumeCapability
        let mute: AudioVolumeMuteState
        let canUnmute: Bool
        let decibels: Float?

        init(objectID: UInt32 = 41, value: Float?, capability: AudioVolumeCapability = .writable(.main),
             mute: AudioVolumeMuteState = .unmuted, canUnmute: Bool = false, decibels: Float? = nil) {
            self.objectID = objectID
            self.value = value
            self.capability = capability
            self.mute = mute
            self.canUnmute = canUnmute
            self.decibels = decibels
        }
    }

    enum Event: Equatable, Sendable {
        case read(Float?, AudioVolumeMuteState)
        case volume(Float)
        case unmuteAttempt(Float)
        case unmute(Float)
        case rejected
    }

    private var states: [State]
    private let cancelPermitAfterVolume: Bool
    private let afterUnmute: [State]?
    private let afterRecovery: [State]?
    private let volumeFailure: AudioVolumeIssue?
    private let unmuteFailure: AudioVolumeIssue?
    private let recoveryFailure: AudioVolumeIssue?
    private let cancelPermitAfterUnmute: Bool
    private let equivalentTarget: AudioVolumeEquivalentTarget?
    private let gate = AudioShutdownSignal()
    private var readIndex = 0
    private var events: [Event] = []
    private var current: State

    init(states: [State], cancelPermitAfterVolume: Bool = false,
         afterUnmute: [State]? = nil, afterRecovery: [State]? = nil,
         volumeFailure: AudioVolumeIssue? = nil, unmuteFailure: AudioVolumeIssue? = nil,
         recoveryFailure: AudioVolumeIssue? = nil, cancelPermitAfterUnmute: Bool = false,
         equivalentTarget: AudioVolumeEquivalentTarget? = nil) {
        precondition(!states.isEmpty)
        self.states = states
        self.current = states[0]
        self.cancelPermitAfterVolume = cancelPermitAfterVolume
        self.afterUnmute = afterUnmute
        self.afterRecovery = afterRecovery
        self.volumeFailure = volumeFailure
        self.unmuteFailure = unmuteFailure
        self.recoveryFailure = recoveryFailure
        self.cancelPermitAfterUnmute = cancelPermitAfterUnmute
        self.equivalentTarget = equivalentTarget
    }

    func inspectVolume(for target: AudioVolumeTarget, expectation: AudioVolumeWriteExpectation?) throws -> AudioVolumeInspection {
        current = states[min(readIndex, states.count - 1)]
        readIndex += 1
        events.append(.read(current.value, current.mute))
        return inspection(for: target)
    }

    private func inspection(for target: AudioVolumeTarget) -> AudioVolumeInspection {
        AudioVolumeInspection(objectID: current.objectID,
            snapshot: AudioVolumeSnapshot(target: target, value: current.value,
                capability: current.capability, mute: current.mute, canUnmute: current.canUnmute), decibels: current.decibels)
    }

    func prepareWriteExpectation(_ value: Float, for target: AudioVolumeTarget,
                                 expectedObject: UInt32) throws -> AudioVolumeWriteExpectation {
        AudioVolumeWriteExpectation(requestedScalar: value, equivalent: value > 0 ? equivalentTarget : nil)
    }

    func submitVolume(_ expectation: AudioVolumeWriteExpectation, for target: AudioVolumeTarget, expectedObject: UInt32,
                      permit: AudioMutationPermit) throws {
        let value = expectation.requestedScalar
        guard current.objectID == expectedObject else { throw AudioVolumeIssue.identityChanged }
        guard gate.performIfRunning(permit: permit, { events.append(.volume(value)) }) else {
            events.append(.rejected)
            throw CancellationError()
        }
        if cancelPermitAfterVolume { permit.cancel() }
        if let volumeFailure { throw volumeFailure }
    }

    func submitUnmute(for target: AudioVolumeTarget, expectedObject: UInt32,
                      expectation: AudioVolumeUnmuteExpectation, permit: AudioMutationPermit) throws {
        let requested = expectation.requestedValue
        events.append(.unmuteAttempt(requested))
        guard current.objectID == expectedObject else { throw AudioVolumeIssue.identityChanged }
        switch expectation {
        case let .confirmedVolume(write):
            guard write.confirms(inspection(for: target)) else { throw AudioVolumeIssue.unconfirmed }
        case let .unconfirmedMutedVolume(_, observed):
            guard requested > 0, current.value == observed, current.mute.isAudiblyMuted, current.canUnmute else {
                throw AudioVolumeIssue.unconfirmed
            }
        }
        guard gate.performIfRunning(permit: permit, { events.append(.unmute(requested)) }) else {
            events.append(.rejected)
            throw CancellationError()
        }
        if let afterUnmute { states = afterUnmute; readIndex = 0 }
        if cancelPermitAfterUnmute { permit.cancel() }
        if let unmuteFailure { throw unmuteFailure }
    }

    func submitVolumeAfterUnmute(_ expectation: AudioVolumeWriteExpectation, for target: AudioVolumeTarget, expected: AudioVolumeInspection,
                                permit: AudioMutationPermit) throws {
        let value = expectation.requestedScalar
        guard current.objectID == expected.objectID else { throw AudioVolumeIssue.identityChanged }
        guard current.mute == .unmuted, current.value == expected.snapshot.value else {
            throw AudioVolumeIssue.unconfirmed
        }
        guard gate.performIfRunning(permit: permit, { events.append(.volume(value)) }) else {
            events.append(.rejected)
            throw CancellationError()
        }
        if let afterRecovery { states = afterRecovery; readIndex = 0 }
        if let recoveryFailure { throw recoveryFailure }
    }

    func recordedEvents() -> [Event] { events }
}
