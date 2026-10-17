import AudioToolbox
import CoreAudio
import Foundation
import XCTest
@testable import ToneHop

/// These tests enter the real HAL actor through its volume API. The only HAL
/// implementation supplied here is the locked fake below; no device is opened,
/// selected, connected, or written by a test.
@MainActor
final class CoreAudioVolumeTests: XCTestCase {
    func testServiceResetRejectsOldVolumeTargetBeforeAnySubmission() async throws {
        let io = VolumeHALFake()
        let service = CoreAudioService(volumeIO: io)
        let epoch = try XCTUnwrap(service.serviceEpoch)
        let old = epoch.capture()
        let target = AudioVolumeTarget(deviceID: "hal:volume", uid: "volume", serviceGeneration: old.id)
        epoch.reset(ifCurrent: old.id)
        do {
            _ = try await service.setVolume(0.8, for: target, permit: AudioMutationPermit())
            XCTFail("A queued request from the old service must not resolve into the new service.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .identityChanged) }
        XCTAssertTrue(io.mutations.isEmpty)
        XCTAssertTrue(io.resolvedUIDs.isEmpty)
    }

    func testServiceResetAfterAdmittedVolumeWritePreventsUnmuteContinuation() async throws {
        let io = VolumeHALFake()
        let service = CoreAudioService(volumeIO: io)
        let epoch = try XCTUnwrap(service.serviceEpoch)
        let old = epoch.capture()
        let target = AudioVolumeTarget(deviceID: "hal:volume", uid: "volume", serviceGeneration: old.id)
        io.configure {
            $0.mutes[0] = .init(value: 1, writable: true)
            $0.resetEpochAfterScalarWrite = epoch
        }
        do {
            _ = try await service.setVolume(0.8, for: target, permit: AudioMutationPermit())
            XCTFail("Reset cannot confirm a pre-reset write or authorize its unmute continuation.")
        } catch is AudioServiceResetError { }
        XCTAssertEqual(io.mutations.count, 1)
        XCTAssertEqual(io.muteValue(element: 0), 1)
        XCTAssertFalse(old.permit.isActive)
    }

    func testMainVolumeUsesItsOwnWritableEvidence() async throws {
        let io = VolumeHALFake()
        let service = CoreAudioService(volumeIO: io)
        let target = target()

        let result = try await service.readVolume(for: target)

        XCTAssertEqual(result.target, target)
        XCTAssertEqual(result.value, 0.25)
        XCTAssertEqual(result.capability, .writable(.main))
        XCTAssertEqual(result.mute, .unsupported)
        XCTAssertFalse(result.canUnmute)
        XCTAssertTrue(io.mutations.isEmpty)
        XCTAssertEqual(io.resolvedUIDs, [target.uid, target.uid])
    }

    func testAbsentScalarPropertiesAreUnsupported() async throws {
        let io = VolumeHALFake()
        io.configure { $0.scalars = [:] }

        let result = try await CoreAudioService(volumeIO: io).readVolume(for: target())

        XCTAssertNil(result.value)
        XCTAssertEqual(result.capability, .unavailable(.unsupported))
        XCTAssertTrue(io.mutations.isEmpty)
    }

    func testReadOnlyMainDoesNotBorrowWritableVirtualControl() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.scalars[.mainScalar] = .init(value: 0.25, writable: false)
            $0.scalars[.virtualScalar] = .init(value: 0.8, writable: true)
        }
        let service = CoreAudioService(volumeIO: io)
        let target = target()

        let result = try await service.readVolume(for: target)
        XCTAssertEqual(result.value, 0.25)
        XCTAssertEqual(result.capability, .unavailable(.readOnly))
        do {
            _ = try await service.setVolume(0.5, for: target, permit: AudioMutationPermit())
            XCTFail("Read-only evidence must reject the write.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .readOnly) }
        XCTAssertTrue(io.mutations.isEmpty)
    }

    func testVirtualOnlyControlIsAnImplementationGap() async throws {
        let io = VolumeHALFake()
        io.configure { $0.scalars = [.virtualScalar: .init(value: 0.35, writable: true)] }

        let result = try await CoreAudioService(volumeIO: io).readVolume(for: target())

        XCTAssertEqual(result.value, 0.35)
        XCTAssertEqual(result.capability, .unavailable(.implementationGap))
    }

    func testChannelOnlyControlsKeepBalanceAndReportImplementationGap() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.scalars = [
                .scalar(1): .init(value: 0.2, writable: true),
                .scalar(2): .init(value: 0.6, writable: true)
            ]
        }
        let service = CoreAudioService(volumeIO: io)
        let target = target()

        let result = try await service.readVolume(for: target)
        XCTAssertEqual(result.value, 0.6)
        XCTAssertEqual(result.capability, .unavailable(.implementationGap))
        do {
            _ = try await service.setVolume(0.8, for: target, permit: AudioMutationPermit())
            XCTFail("An unverified fallback must not write individual channels.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .implementationGap) }
        XCTAssertTrue(io.mutations.isEmpty)
        XCTAssertEqual(io.scalarValue(element: 1), 0.2)
        XCTAssertEqual(io.scalarValue(element: 2), 0.6)
    }

    func testScalarReadFailureIsNotReportedAsUnsupported() async {
        let io = VolumeHALFake()
        io.configure { $0.scalarErrors[.mainScalar] = .readFailed(-901) }
        do {
            _ = try await CoreAudioService(volumeIO: io).readVolume(for: target())
            XCTFail("A failed property read must remain a read failure.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .readFailed(-901)) }
        XCTAssertTrue(io.mutations.isEmpty)
    }

    func testObjectReplacementDuringCompoundReadRejectsIdentity() async {
        let io = VolumeHALFake()
        io.configure { $0.objectSequence = [41, 42] }
        do {
            _ = try await CoreAudioService(volumeIO: io).readVolume(for: target())
            XCTFail("The same UID resolving to a different object invalidates this compound read.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .identityChanged) }
        XCTAssertTrue(io.mutations.isEmpty)
    }

    func testPositiveWriteOnlyMutatesPreciseObjectMainVolume() async throws {
        let io = VolumeHALFake()
        io.configure { $0.mutes[0] = .init(value: 0, writable: true) }
        let service = CoreAudioService(volumeIO: io)

        let result = try await service.setVolume(0.65, for: target(), permit: AudioMutationPermit())

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.value, 0.65)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.65)])
        // The injected boundary exposes output volume/mute only. A routing or
        // default-device setter cannot be smuggled into one of these calls.
        XCTAssertEqual(Set(io.resolvedUIDs), ["test-output-uid"])
    }

    func testEquivalentScalarRequiresDriverConversionAndMatchingActualDecibels() async throws {
        let io = quantizedIO()

        let result = try await CoreAudioService(volumeIO: io).setVolume(0.44, for: target(), permit: AudioMutationPermit())

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.value, 0.4375)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.44)], "Submit the original request, not the equivalent or observed value.")
    }

    func testEquivalentScalarWithMissingWrongOrNonfiniteActualDecibelsRemainsUnconfirmed() async throws {
        let actualValues: [Float?] = [nil, -11, .nan, -.infinity]
        for actual in actualValues {
            let io = quantizedIO()
            io.configure { $0.actualDecibels = actual; $0.decibelsAfterScalarWrite = actual }

            let result = try await runWithoutReadbackDelay(0.44, io: io)

            XCTAssertEqual(result.issue, .unconfirmed)
            XCTAssertEqual(result.snapshot.value, 0.4375)
            XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.44)])
        }
    }

    func testContinuousConversionCannotAuthorizeNearbyScalarReadback() async throws {
        let io = quantizedIO()
        io.configure { $0.decibelsToScalar[-10] = 0.44 }

        let result = try await runWithoutReadbackDelay(0.44, io: io)

        XCTAssertEqual(result.issue, .unconfirmed, "A continuous scalar/dB conversion does not reveal a quantization step.")
        XCTAssertEqual(result.snapshot.value, 0.4375)
    }

    func testInvalidConversionRangeRoundTripOrFixedPointCannotSupplyEquivalentTarget() async throws {
        for invalidMapping in 0..<5 {
            let io = quantizedIO()
            io.configure {
                switch invalidMapping {
                case 0: $0.decibelRange = .init(minimum: .nan, maximum: 0)
                case 1: $0.decibelRange = .init(minimum: -5, maximum: 0)
                case 2: $0.decibelsToScalar[-10] = 1.1
                case 3: $0.scalarToDecibels[0.4375] = -11
                default: $0.inverseSequence = [0.4375, 0.5]
                }
            }
            let service = CoreAudioService(volumeIO: io)
            let expectation = try await service.prepareWriteExpectation(0.44, for: target(), expectedObject: 41)
            XCTAssertNil(expectation.equivalent, "Malformed conversion variant \(invalidMapping) must retain exact confirmation only.")
            XCTAssertTrue(io.mutations.isEmpty, "Conversion preparation is read-only.")
        }
    }

    func testConversionEvidenceMustRemainStableAcrossItsTwoReads() async throws {
        let io = quantizedIO()
        io.configure { $0.decibelRangeSequence = [.init(minimum: -80, maximum: 0), .init(minimum: -90, maximum: 0)] }
        let service = CoreAudioService(volumeIO: io)

        let expectation = try await service.prepareWriteExpectation(0.44, for: target(), expectedObject: 41)

        XCTAssertNil(expectation.equivalent)
        XCTAssertTrue(io.mutations.isEmpty)
    }

    func testUnavailableConversionLeavesExactScalarWriteUsable() async throws {
        let io = quantizedIO()
        io.configure { $0.conversionError = .readFailed(-951); $0.scalarWriteReadback = nil }

        let result = try await CoreAudioService(volumeIO: io).setVolume(0.44, for: target(), permit: AudioMutationPermit())

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.value, 0.44)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.44)])
    }

    func testPreparedMappingIsRevalidatedBeforeInitialVolumeSubmission() async throws {
        let io = quantizedIO()
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        let expectation = try await service.prepareWriteExpectation(0.44, for: target, expectedObject: 41)
        XCTAssertNotNil(expectation.equivalent)
        io.configure { $0.decibelRange = nil }

        do {
            try await service.submitVolume(expectation, for: target, expectedObject: 41, permit: AudioMutationPermit())
            XCTFail("A revoked mapping cannot be downgraded or replaced while submitting the same request.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .unconfirmed) }
        XCTAssertTrue(io.mutations.isEmpty)
    }

    func testMappingRevokedAfterVolumeWriteStopsBeforeAnyUnmute() async {
        let io = quantizedIO()
        io.configure { $0.mutes[0] = .init(value: 1, writable: true); $0.removeConversionsAfterScalarWrite = true }

        do {
            _ = try await runWithoutReadbackDelay(0.44, io: io)
            XCTFail("A known mapping cannot silently disappear after the first write.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .unconfirmed) }
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.44)])
        XCTAssertEqual(io.muteValue(element: 0), 1)
    }

    func testChangingScalarDecibelPairDoesNotConfirmEquivalentTarget() async throws {
        let io = quantizedIO()
        io.configure {
            $0.scalars[.mainScalar] = .init(value: 0.4375, writable: true)
            $0.actualDecibelSequence = [-10, -11]
        }
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        let expectation = try await service.prepareWriteExpectation(0.44, for: target, expectedObject: 41)

        let actual = try await service.inspectVolume(for: target, expectation: expectation)

        XCTAssertNil(actual.decibels)
        XCTAssertFalse(expectation.confirms(actual))
        XCTAssertEqual(actual.snapshot.value, 0.4375)
        XCTAssertTrue(io.mutations.isEmpty)
    }

    func testZeroDoesNotConsultConversionsOrAcceptNonzeroEquivalent() async throws {
        let io = quantizedIO()
        io.configure { $0.scalarWriteReadback = Float.leastNonzeroMagnitude }

        let result = try await runWithoutReadbackDelay(0, io: io)

        XCTAssertEqual(result.issue, .unconfirmed)
        XCTAssertEqual(io.conversionReads, 0)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0)])
    }

    func testConfirmedEquivalentVolumeCanUnmuteAfterJointReadback() async throws {
        let io = quantizedIO()
        io.configure { $0.mutes[0] = .init(value: 1, writable: true) }

        let result = try await CoreAudioService(volumeIO: io).setVolume(0.44, for: target(), permit: AudioMutationPermit())

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.value, 0.4375)
        XCTAssertEqual(result.snapshot.mute, .unmuted)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.44), .mute(object: 41, element: 0, value: 0)])
    }

    func testMutedIgnoredWriteRecoversOnceAndConfirmsEquivalentScalarWithActualDecibels() async throws {
        let io = quantizedIO()
        io.configure {
            $0.scalars[.mainScalar] = .init(value: 0, writable: true)
            $0.mutes[0] = .init(value: 1, writable: true)
            $0.ignoredScalarWriteNumbers = [1]
            $0.changeScalarAfterMute = (element: 0, value: 0.75)
            $0.decibelsAfterMuteWrite = -2
        }

        let result = try await runWithoutReadbackDelay(0.44, io: io)

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.value, 0.4375)
        XCTAssertEqual(result.snapshot.mute, .unmuted)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.44), .mute(object: 41, element: 0, value: 0),
                                     .scalar(object: 41, value: 0.44)])
    }

    func testMappingRevokedAfterUnmuteCannotAuthorizeRecoveryWrite() async {
        let io = quantizedIO()
        io.configure {
            $0.scalars[.mainScalar] = .init(value: 0, writable: true)
            $0.mutes[0] = .init(value: 1, writable: true)
            $0.ignoredScalarWriteNumbers = [1]
            $0.changeScalarAfterMute = (element: 0, value: 0.75)
            $0.decibelsAfterMuteWrite = -2
            $0.removeConversionsAfterMuteWrite = true
        }

        do {
            _ = try await runWithoutReadbackDelay(0.44, io: io)
            XCTFail("The already performed unmute does not authorize a write using revoked conversion evidence.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .unconfirmed) }
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.44), .mute(object: 41, element: 0, value: 0)])
        XCTAssertEqual(io.muteValue(element: 0), 0)
    }

    func testRecoveryAdmissionRejectsExternalDecibelChangeEvenWhenScalarIsUnchanged() async throws {
        let io = quantizedIO()
        io.configure { $0.mutes[0] = .init(value: 0, writable: true) }
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        let expectation = try await service.prepareWriteExpectation(0.44, for: target, expectedObject: 41)
        let observed = try await service.inspectVolume(for: target, expectation: expectation)
        io.configure { $0.actualDecibels = -21 }

        do {
            try await service.submitVolumeAfterUnmute(expectation, for: target, expected: observed, permit: AudioMutationPermit())
            XCTFail("A new dB state must not be overwritten using an earlier scalar-only observation.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .unconfirmed) }
        XCTAssertTrue(io.mutations.isEmpty)
    }

    func testZeroVolumeDoesNotWriteMuteOrUnmute() async throws {
        let io = VolumeHALFake()
        io.configure { $0.mutes[0] = .init(value: 1, writable: true) }

        let result = try await CoreAudioService(volumeIO: io).setVolume(0, for: target(), permit: AudioMutationPermit())

        XCTAssertEqual(result.issue, .mutedVolumeUnconfirmed)
        XCTAssertEqual(result.snapshot.value, 0)
        XCTAssertEqual(result.snapshot.mute, .muted)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0)])
    }

    func testFailedVolumeSetterDoesNotAttemptUnmute() async {
        let io = VolumeHALFake()
        io.configure {
            $0.mutes[0] = .init(value: 1, writable: true)
            $0.scalarWriteStatus = -905
        }
        do {
            _ = try await CoreAudioService(volumeIO: io).setVolume(0.5, for: target(), permit: AudioMutationPermit())
            XCTFail("A failed volume submission cannot authorize an unmute.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .writeFailed(-905)) }
        XCTAssertEqual(io.scalarValue(element: 0), 0.25)
        XCTAssertEqual(io.muteValue(element: 0), 1)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.5)])
    }

    func testFailedSetterWithLateEffectCanBeReadWithoutCompensatingWrite() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.mutes[0] = .init(value: 1, writable: true)
            $0.scalarWriteStatus = -905
            $0.applyFailedScalarWrite = true
        }
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        do {
            _ = try await service.setVolume(0.5, for: target, permit: AudioMutationPermit())
            XCTFail("A failed setter remains failed even if the remote effect occurred.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .writeFailed(-905)) }

        let actual = try await service.readVolume(for: target)

        XCTAssertEqual(actual.value, 0.5)
        XCTAssertEqual(actual.mute, .muted)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.5)])
    }

    func testUnconfirmedMutedWriteWaitsForUnmutedReadbackBeforeOneVolumeRewrite() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.scalars[.mainScalar] = .init(value: 0, writable: true)
            $0.mutes[0] = .init(value: 1, writable: true)
            $0.ignoredScalarWriteNumbers = [1]
            $0.muteWriteDelayReads = 3
        }

        let result = try await CoreAudioService(volumeIO: io).setVolume(0.5, for: target(), permit: AudioMutationPermit())

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.value, 0.5)
        XCTAssertEqual(result.snapshot.mute, .unmuted)
        XCTAssertEqual(io.mutations, [
            .scalar(object: 41, value: 0.5), .mute(object: 41, element: 0, value: 0),
            .scalar(object: 41, value: 0.5)
        ])
        let events = io.events
        let unmute = try XCTUnwrap(events.firstIndex(of: .muteWrite(element: 0, value: 0)))
        let rewrite = try XCTUnwrap(events.lastIndex(of: .scalarWrite(0.5)))
        let between = events[(unmute + 1)..<rewrite]
        XCTAssertTrue(between.contains(.muteRead(element: 0, value: 1)), "A successful setter alone is not mute readback.")
        XCTAssertTrue(between.contains(.muteRead(element: 0, value: 0)), "The extra volume write must follow an actual mute=0 read.")
    }

    func testUnconfirmedUnmuteErrorWithActualEffectDoesNotRewriteVolume() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.scalars[.mainScalar] = .init(value: 0, writable: true)
            $0.mutes[0] = .init(value: 1, writable: true)
            $0.ignoredScalarWriteNumbers = [1]
            $0.muteWriteStatus[0] = -906
            $0.applyFailedMuteWrite = true
        }
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        do {
            let result = try await service.setVolume(0.5, for: target, permit: AudioMutationPermit())
            XCTAssertNotNil(result.issue, "An unmute error remains unconfirmed even if it changed the device.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .writeFailed(-906)) }

        let actual = try await service.readVolume(for: target)
        XCTAssertEqual(actual.value, 0)
        XCTAssertEqual(actual.mute, .unmuted)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.5), .mute(object: 41, element: 0, value: 0)])
    }

    func testUnknownMuteReadbackAfterFallbackDoesNotRewriteVolume() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.scalars[.mainScalar] = .init(value: 0, writable: true)
            $0.mutes[0] = .init(value: 1, writable: true)
            $0.ignoredScalarWriteNumbers = [1]
            $0.muteErrorsAfterWrite[0] = .readFailed(-907)
        }

        let result = try await CoreAudioService(volumeIO: io).setVolume(0.5, for: target(), permit: AudioMutationPermit())

        XCTAssertNotNil(result.issue)
        XCTAssertEqual(result.snapshot.mute, .unknown)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.5), .mute(object: 41, element: 0, value: 0)])
    }

    func testUnconfirmedRewriteHasOneAttemptAndRequiresJointReadback() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.scalars[.mainScalar] = .init(value: 0, writable: true)
            $0.mutes[0] = .init(value: 1, writable: true)
            $0.ignoredScalarWriteNumbers = [1, 2]
        }

        let result = try await CoreAudioService(volumeIO: io).setVolume(0.5, for: target(), permit: AudioMutationPermit())

        XCTAssertEqual(result.issue, .unmutedVolumeUnconfirmed)
        XCTAssertEqual(result.snapshot.value, 0)
        XCTAssertEqual(result.snapshot.mute, .unmuted)
        XCTAssertEqual(io.mutations, [
            .scalar(object: 41, value: 0.5), .mute(object: 41, element: 0, value: 0),
            .scalar(object: 41, value: 0.5)
        ], "An unsuccessful readback must not loop into a third volume write.")
    }

    func testCanceledPermitAfterFallbackUnmutePreventsVolumeRewrite() async {
        let io = VolumeHALFake()
        let permit = AudioMutationPermit()
        io.configure {
            $0.scalars[.mainScalar] = .init(value: 0, writable: true)
            $0.mutes[0] = .init(value: 1, writable: true)
            $0.ignoredScalarWriteNumbers = [1]
            $0.cancelPermitAfterMuteWrite = permit
        }
        do {
            _ = try await CoreAudioService(volumeIO: io).setVolume(0.5, for: target(), permit: permit)
            XCTFail("The fallback and rewrite must share the original, now-cancelled permit.")
        } catch is CancellationError {
            // The already-admitted unmute may finish; the subsequent volume cannot enter.
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.5), .mute(object: 41, element: 0, value: 0)])
    }

    func testRewriteAdmissionRechecksMuteOnTheHALActor() async throws {
        let io = VolumeHALFake()
        io.configure { $0.mutes[0] = .init(value: 0, writable: true) }
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        let expected = try await service.inspectVolume(for: target)
        io.configure { $0.mutes[0] = .init(value: 1, writable: true) }

        do {
            try await service.submitVolumeAfterUnmute(.init(requestedScalar: 0.5), for: target, expected: expected, permit: AudioMutationPermit())
            XCTFail("A newer mute cannot be overridden using the transaction's earlier unmuted readback.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .unconfirmed) }
        XCTAssertTrue(io.mutations.isEmpty)
    }

    func testRewriteAdmissionRechecksExternalVolumeOnTheHALActor() async throws {
        let io = VolumeHALFake()
        io.configure { $0.mutes[0] = .init(value: 0, writable: true) }
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        let expected = try await service.inspectVolume(for: target)
        io.configure { $0.scalars[.mainScalar] = .init(value: 0.8, writable: true) }

        do {
            try await service.submitVolumeAfterUnmute(.init(requestedScalar: 0.5), for: target, expected: expected, permit: AudioMutationPermit())
            XCTFail("The rewrite must preserve an external change after the transaction's readback.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .unconfirmed) }
        XCTAssertTrue(io.mutations.isEmpty)
        XCTAssertEqual(io.scalarValue(element: 0), 0.8)
    }

    func testFallbackUnmuteStopsRemainingChannelsWhenObservedVolumeChanges() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.scalars[.mainScalar] = .init(value: 0, writable: true)
            $0.mutes = [1: .init(value: 1, writable: true), 2: .init(value: 1, writable: true)]
            $0.changeScalarAfterMute = (element: 1, value: 0.8)
        }
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        do {
            try await service.submitUnmute(for: target, expectedObject: 41,
                expectation: .unconfirmedMutedVolume(write: .init(requestedScalar: 0.5), observedValue: 0), permit: AudioMutationPermit())
            XCTFail("Fallback only authorizes the observed value; a later change stops remaining channel writes.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .unconfirmed) }
        let actual = try await service.readVolume(for: target)
        XCTAssertEqual(actual.value, 0.8)
        XCTAssertEqual(actual.mute, .mixed)
        XCTAssertEqual(io.mutations, [.mute(object: 41, element: 1, value: 0)])
    }

    func testMissingMainMuteReadsAndUnmutesBothMutedChannels() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.mutes = [1: .init(value: 1, writable: true), 2: .init(value: 1, writable: true)]
        }
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        let before = try await service.readVolume(for: target)
        XCTAssertEqual(before.mute, .muted)
        XCTAssertTrue(before.canUnmute)

        let result = try await service.setVolume(0.5, for: target, permit: AudioMutationPermit())

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.mute, .unmuted)
        XCTAssertEqual(io.mutations, [
            .scalar(object: 41, value: 0.5),
            .mute(object: 41, element: 1, value: 0),
            .mute(object: 41, element: 2, value: 0)
        ])
    }

    func testMissingMainMuteReadsMixedChannelsAndOnlyUnmutesMutedOne() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.mutes = [1: .init(value: 0, writable: false), 2: .init(value: 1, writable: true)]
        }
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        let before = try await service.readVolume(for: target)
        XCTAssertEqual(before.mute, .mixed)
        XCTAssertTrue(before.canUnmute, "An already-unmuted read-only channel needs no write.")

        let result = try await service.setVolume(0.5, for: target, permit: AudioMutationPermit())

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.mute, .unmuted)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.5), .mute(object: 41, element: 2, value: 0)])
    }

    func testMainMuteDoesNotHideAnAdditionalMutedChannel() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.mutes = [
                0: .init(value: 1, writable: true),
                1: .init(value: 1, writable: true),
                2: .init(value: 0, writable: true)
            ]
        }

        let result = try await CoreAudioService(volumeIO: io).setVolume(0.5, for: target(), permit: AudioMutationPermit())

        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.mute, .unmuted)
        XCTAssertEqual(io.mutations, [
            .scalar(object: 41, value: 0.5),
            .mute(object: 41, element: 0, value: 0),
            .mute(object: 41, element: 1, value: 0)
        ])
    }

    func testReadOnlyMutedChannelPreventsPartialUnmuteAndReportsStillMuted() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.mutes = [1: .init(value: 1, writable: true), 2: .init(value: 1, writable: false)]
        }
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        let before = try await service.readVolume(for: target)
        XCTAssertEqual(before.mute, .muted)
        XCTAssertFalse(before.canUnmute)

        let result = try await service.setVolume(0.5, for: target, permit: AudioMutationPermit())

        XCTAssertEqual(result.issue, .stillMuted)
        XCTAssertEqual(result.snapshot.value, 0.5)
        XCTAssertEqual(result.snapshot.mute, .muted)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.5)])
    }

    func testSecondChannelUnmuteFailureRetainsActualMixedState() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.mutes = [1: .init(value: 1, writable: true), 2: .init(value: 1, writable: true)]
            $0.muteWriteStatus[2] = -902
        }

        let result = try await CoreAudioService(volumeIO: io).setVolume(0.5, for: target(), permit: AudioMutationPermit())

        XCTAssertEqual(result.issue, .stillMuted)
        XCTAssertEqual(result.snapshot.mute, .mixed)
        XCTAssertEqual(io.muteValue(element: 1), 0)
        XCTAssertEqual(io.muteValue(element: 2), 1)
        XCTAssertEqual(io.mutations, [
            .scalar(object: 41, value: 0.5),
            .mute(object: 41, element: 1, value: 0),
            .mute(object: 41, element: 2, value: 0)
        ])
    }

    func testExternalVolumeChangeBetweenChannelUnmutesStopsWithoutCompensation() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.mutes = [1: .init(value: 1, writable: true), 2: .init(value: 1, writable: true)]
            $0.changeScalarAfterMute = (element: 1, value: 0.8)
        }
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        do {
            _ = try await service.setVolume(0.1, for: target, permit: AudioMutationPermit())
            XCTFail("An external volume change revokes confirmation before the second channel's unmute.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .unconfirmed) }

        let actual = try await service.readVolume(for: target)

        XCTAssertEqual(actual.value, 0.8)
        XCTAssertEqual(actual.mute, .mixed)
        XCTAssertEqual(io.muteValue(element: 1), 0)
        XCTAssertEqual(io.muteValue(element: 2), 1)
        XCTAssertEqual(io.mutations, [
            .scalar(object: 41, value: 0.1),
            .mute(object: 41, element: 1, value: 0)
        ], "Reconciliation is read-only; neither the changed volume nor the remaining mute is overwritten.")
    }

    func testChannelMuteReadFailureIsUnknownAndNeverGuessedAway() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.mutes = [1: .init(value: 1, writable: true)]
            $0.muteErrors[2] = .readFailed(-903)
        }
        let service = CoreAudioService(volumeIO: io)
        let target = target()
        let before = try await service.readVolume(for: target)
        XCTAssertEqual(before.mute, .unknown)
        XCTAssertFalse(before.canUnmute)

        let result = try await service.setVolume(0.5, for: target, permit: AudioMutationPermit())

        XCTAssertEqual(result.issue, .muteUnknown)
        XCTAssertEqual(result.snapshot.mute, .unknown)
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.5)])
    }

    func testObjectReplacementAfterVolumeWritePreventsUnmute() async {
        let io = VolumeHALFake()
        io.configure {
            $0.mutes[0] = .init(value: 1, writable: true)
            $0.replaceObjectAfterScalarWrite = 99
        }
        do {
            _ = try await CoreAudioService(volumeIO: io).setVolume(0.5, for: target(), permit: AudioMutationPermit())
            XCTFail("A replaced object must not receive the old request's unmute.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .identityChanged) }
        XCTAssertEqual(io.mutations, [.scalar(object: 41, value: 0.5)])
    }

    func testCanceledPermitRejectsMutationAtActualHALAdmission() async {
        let io = VolumeHALFake()
        let permit = AudioMutationPermit()
        permit.cancel()
        do {
            _ = try await CoreAudioService(volumeIO: io).setVolume(0.5, for: target(), permit: permit)
            XCTFail("Cancellation before gate admission must prevent the setter.")
        } catch is CancellationError {
            // Expected: reading evidence does not consume or reopen a permit.
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(io.mutations.isEmpty)
    }

    func testFailedListenerRemovalClosesCallbackAndRetriesOriginalRegistration() async throws {
        let io = VolumeHALFake()
        let service = CoreAudioService(volumeIO: io)
        let callbacks = VolumeCallbackCounter()
        let target = target()
        try await service.observeVolumeChanges(targets: [target, target]) { callbacks.increment() }
        XCTAssertEqual(io.listenerAddCount, 1, "Duplicate targets for one object must not duplicate listeners.")
        io.fireListener(at: 0)
        XCTAssertEqual(callbacks.count, 1)

        io.configure { $0.listenerRemovalStatuses = [-904, -904, noErr] }
        await service.stopObservingVolume()
        io.fireListener(at: 0)
        XCTAssertEqual(callbacks.count, 1, "A failed remove must still close its callback capsule.")
        do {
            try await service.observeVolumeChanges(targets: [target]) { callbacks.increment() }
            XCTFail("A retained failed removal must be retried before registering new listeners.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .listenerUnavailable) }
        XCTAssertEqual(io.listenerAddCount, 1)

        try await service.observeVolumeChanges(targets: [target]) { callbacks.increment() }
        XCTAssertEqual(io.listenerAddCount, 2)
        XCTAssertEqual(io.listenerRemovalMatches, [true, true, true],
                       "Retry must retain the original object/address/queue/native token/delivery tuple.")
        io.fireListener(at: 0)
        XCTAssertEqual(callbacks.count, 1)
        io.fireListener(at: 1)
        XCTAssertEqual(callbacks.count, 2)
        await service.stopObservingVolume()
        io.fireListener(at: 1)
        XCTAssertEqual(callbacks.count, 2)
    }

    func testBadObjectListenerRemovalDoesNotLeakARetryHandle() async throws {
        let io = VolumeHALFake()
        let service = CoreAudioService(volumeIO: io)
        let callbacks = VolumeCallbackCounter()
        try await service.observeVolumeChanges(targets: [target()]) { callbacks.increment() }
        io.configure { $0.listenerRemovalStatuses = [kAudioHardwareBadObjectError] }
        await service.stopObservingVolume()

        try await service.observeVolumeChanges(targets: [target()]) { callbacks.increment() }

        XCTAssertEqual(io.listenerAddCount, 2)
        XCTAssertEqual(io.listenerRemovalMatches.count, 1)
        io.fireListener(at: 0)
        XCTAssertEqual(callbacks.count, 0)
        await service.stopObservingVolume()
    }

    func testPartialListenerInstallFailureClosesOnlyTheInstalledRegistrations() async throws {
        let io = VolumeHALFake()
        io.configure {
            $0.observableProperties.insert(VolumeProperty(kAudioDevicePropertyMute))
            $0.listenerAddFailureAt = 2
        }
        let service = CoreAudioService(volumeIO: io)
        let callbacks = VolumeCallbackCounter()
        do {
            try await service.observeVolumeChanges(targets: [target()]) { callbacks.increment() }
            XCTFail("The second listener's failure must remain observable.")
        } catch { XCTAssertEqual(error as? AudioVolumeIssue, .listenerUnavailable) }
        XCTAssertEqual(io.listenerAddCount, 1)
        XCTAssertEqual(io.listenerRemovalMatches, [true])
        io.fireListener(at: 0)
        XCTAssertEqual(callbacks.count, 0)

        try await service.observeVolumeChanges(targets: [target()]) { callbacks.increment() }

        XCTAssertEqual(io.listenerAddCount, 3)
        XCTAssertEqual(io.listenerRemovalMatches.count, 1,
                       "A successfully removed partial install must not be removed again.")
        io.fireListener(at: 1)
        io.fireListener(at: 2)
        XCTAssertEqual(callbacks.count, 2)
        await service.stopObservingVolume()
    }

    private func quantizedIO() -> VolumeHALFake {
        let io = VolumeHALFake()
        io.configure {
            $0.decibelRange = .init(minimum: -80, maximum: 0)
            $0.scalarToDecibels = [0.44: -10, 0.4375: -10]
            $0.decibelsToScalar = [-10: 0.4375]
            $0.actualDecibels = -20
            $0.scalarWriteReadback = 0.4375
            $0.decibelsAfterScalarWrite = -10
        }
        return io
    }

    private func runWithoutReadbackDelay(_ value: Float, io: VolumeHALFake) async throws -> AudioVolumeWriteResult {
        // The production transaction and real HAL actor run unchanged; only
        // its polling budget and native IO are injected for deterministic tests.
        try await AudioVolumeTransaction.run(value: value, target: target(), permit: AudioMutationPermit(),
                                             access: CoreAudioService(volumeIO: io), timeout: .zero)
    }

    private func target() -> AudioVolumeTarget {
        AudioVolumeTarget(deviceID: "hal:test-output-uid", uid: "test-output-uid")
    }
}

private struct VolumeProperty: Hashable {
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    let element: UInt32

    init(_ selector: AudioObjectPropertySelector, element: UInt32 = 0,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) {
        self.selector = selector
        self.scope = scope
        self.element = element
    }
    init(_ address: AudioObjectPropertyAddress) {
        self.init(address.mSelector, element: address.mElement, scope: address.mScope)
    }
    static let mainScalar = VolumeProperty(kAudioDevicePropertyVolumeScalar)
    static let virtualScalar = VolumeProperty(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    static func scalar(_ element: UInt32) -> Self { Self(kAudioDevicePropertyVolumeScalar, element: element) }
}

private final class VolumeCallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class VolumeHALFake: CoreAudioVolumeIO, @unchecked Sendable {
    enum Mutation: Equatable {
        case scalar(object: AudioObjectID, value: Float)
        case mute(object: AudioObjectID, element: UInt32, value: UInt32)
    }
    enum Event: Equatable {
        case scalarWrite(Float)
        case muteWrite(element: UInt32, value: UInt32)
        case muteRead(element: UInt32, value: UInt32?)
    }
    struct State {
        var object: AudioObjectID = 41
        var objectSequence: [AudioObjectID] = []
        var resolvedUIDs: [String] = []
        var scalars: [VolumeProperty: AudioVolumePropertyEvidence] = [.mainScalar: .init(value: 0.25, writable: true)]
        var scalarErrors: [VolumeProperty: AudioVolumeIssue] = [:]
        var decibelRange: AudioVolumeDecibelRange?
        var decibelRangeSequence: [AudioVolumeDecibelRange] = []
        var scalarToDecibels: [Float: Float] = [:]
        var decibelsToScalar: [Float: Float] = [:]
        var inverseSequence: [Float] = []
        var conversionError: AudioVolumeIssue?
        var conversionReads = 0
        var actualDecibels: Float?
        var actualDecibelSequence: [Float] = []
        var scalarWriteReadback: Float?
        var decibelsAfterScalarWrite: Float?
        var decibelsAfterMuteWrite: Float?
        var removeConversionsAfterScalarWrite = false
        var removeConversionsAfterMuteWrite = false
        var mutes: [UInt32: AudioVolumeMuteEvidence] = [:]
        var muteErrors: [UInt32: AudioVolumeIssue] = [:]
        var elements: [UInt32] = [1, 2]
        var mutations: [Mutation] = []
        var events: [Event] = []
        var scalarWriteCount = 0
        var ignoredScalarWriteNumbers: Set<Int> = []
        var scalarWriteStatus: OSStatus = noErr
        var applyFailedScalarWrite = false
        var muteWriteStatus: [UInt32: OSStatus] = [:]
        var applyFailedMuteWrite = false
        var muteWriteDelayReads = 0
        var pendingMutes: [UInt32: (value: UInt32, writable: Bool, remaining: Int)] = [:]
        var muteErrorsAfterWrite: [UInt32: AudioVolumeIssue] = [:]
        var changeScalarAfterMute: (element: UInt32, value: Float)?
        var replaceObjectAfterScalarWrite: AudioObjectID?
        var resetEpochAfterScalarWrite: AudioServiceEpoch?
        var cancelPermitAfterMuteWrite: AudioMutationPermit?
        var observableProperties: Set<VolumeProperty> = [.mainScalar]
        var registrations: [CoreAudioVolumeObservationState.Registration] = []
        var listenerAddAttempts = 0
        var listenerAddFailureAt: Int?
        var listenerRemovalStatuses: [OSStatus] = []
        var listenerRemovalMatches: [Bool] = []
    }
    private let lock = NSLock()
    private var state = State()

    func configure(_ mutation: (inout State) -> Void) { lock.withLock { mutation(&state) } }
    var mutations: [Mutation] { lock.withLock { state.mutations } }
    var events: [Event] { lock.withLock { state.events } }
    var resolvedUIDs: [String] { lock.withLock { state.resolvedUIDs } }
    var listenerAddCount: Int { lock.withLock { state.registrations.count } }
    var listenerRemovalMatches: [Bool] { lock.withLock { state.listenerRemovalMatches } }
    var conversionReads: Int { lock.withLock { state.conversionReads } }
    func scalarValue(element: UInt32) -> Float? { lock.withLock { state.scalars[.scalar(element)]?.value } }
    func muteValue(element: UInt32) -> UInt32? { lock.withLock { state.mutes[element]?.value } }

    func outputDevice(uid: String) throws -> AudioObjectID {
        lock.withLock {
            state.resolvedUIDs.append(uid)
            if !state.objectSequence.isEmpty { return state.objectSequence.removeFirst() }
            return state.object
        }
    }

    func scalar(_ object: AudioObjectID, selector: AudioObjectPropertySelector, element: UInt32) throws -> AudioVolumePropertyEvidence? {
        try lock.withLock {
            let key = VolumeProperty(selector, element: element)
            if let error = state.scalarErrors[key] { throw error }
            return state.scalars[key]
        }
    }

    func decibelRange(_ object: AudioObjectID) throws -> AudioVolumeDecibelRange? {
        try lock.withLock {
            state.conversionReads += 1
            if let error = state.conversionError { throw error }
            if !state.decibelRangeSequence.isEmpty { return state.decibelRangeSequence.removeFirst() }
            return state.decibelRange
        }
    }

    func decibels(_ object: AudioObjectID) throws -> Float? {
        lock.withLock {
            if !state.actualDecibelSequence.isEmpty { return state.actualDecibelSequence.removeFirst() }
            return state.actualDecibels
        }
    }

    func scalarToDecibels(_ object: AudioObjectID, value: Float) throws -> Float? {
        try lock.withLock {
            state.conversionReads += 1
            if let error = state.conversionError { throw error }
            return state.scalarToDecibels[value]
        }
    }

    func decibelsToScalar(_ object: AudioObjectID, value: Float) throws -> Float? {
        try lock.withLock {
            state.conversionReads += 1
            if let error = state.conversionError { throw error }
            if !state.inverseSequence.isEmpty { return state.inverseSequence.removeFirst() }
            return state.decibelsToScalar[value]
        }
    }

    func mute(_ object: AudioObjectID, element: UInt32) throws -> AudioVolumeMuteEvidence? {
        try lock.withLock {
            if let error = state.muteErrors[element] { throw error }
            if var pending = state.pendingMutes[element] {
                if pending.remaining > 0 {
                    pending.remaining -= 1
                    state.pendingMutes[element] = pending
                } else {
                    state.mutes[element] = .init(value: pending.value, writable: pending.writable)
                    state.pendingMutes[element] = nil
                }
            }
            let evidence = state.mutes[element]
            state.events.append(.muteRead(element: element, value: evidence?.value))
            return evidence
        }
    }

    func outputElements(_ object: AudioObjectID) throws -> [UInt32] { lock.withLock { state.elements } }
    func hasProperty(_ object: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        lock.withLock { state.observableProperties.contains(VolumeProperty(address)) }
    }

    func setScalar(_ object: AudioObjectID, value: Float) -> OSStatus {
        lock.withLock {
            state.mutations.append(.scalar(object: object, value: value))
            state.events.append(.scalarWrite(value))
            state.scalarWriteCount += 1
            if !state.ignoredScalarWriteNumbers.contains(state.scalarWriteCount) &&
                (state.scalarWriteStatus == noErr || state.applyFailedScalarWrite) {
                let writable = state.scalars[.mainScalar]?.writable ?? false
                state.scalars[.mainScalar] = .init(value: state.scalarWriteReadback ?? value, writable: writable)
                if let decibels = state.decibelsAfterScalarWrite { state.actualDecibels = decibels }
            }
            if state.removeConversionsAfterScalarWrite { state.decibelRange = nil }
            if let replacement = state.replaceObjectAfterScalarWrite { state.object = replacement }
            if let epoch = state.resetEpochAfterScalarWrite { epoch.reset(ifCurrent: epoch.capture().id) }
            return state.scalarWriteStatus
        }
    }

    func setMute(_ object: AudioObjectID, element: UInt32, value: UInt32) -> OSStatus {
        lock.withLock {
            state.mutations.append(.mute(object: object, element: element, value: value))
            state.events.append(.muteWrite(element: element, value: value))
            let status = state.muteWriteStatus[element] ?? noErr
            if status == noErr || state.applyFailedMuteWrite {
                let writable = state.mutes[element]?.writable ?? false
                if state.muteWriteDelayReads > 0 {
                    state.pendingMutes[element] = (value: value, writable: writable, remaining: state.muteWriteDelayReads)
                } else {
                    state.mutes[element] = .init(value: value, writable: writable)
                }
                if let change = state.changeScalarAfterMute, change.element == element {
                    state.scalars[.mainScalar] = .init(value: change.value,
                                                      writable: state.scalars[.mainScalar]?.writable ?? false)
                }
                if let decibels = state.decibelsAfterMuteWrite { state.actualDecibels = decibels }
            }
            if state.removeConversionsAfterMuteWrite { state.decibelRange = nil }
            state.muteErrors.merge(state.muteErrorsAfterWrite) { _, latest in latest }
            state.cancelPermitAfterMuteWrite?.cancel()
            return status
        }
    }

    func addListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                     changed: @escaping @Sendable () -> Void) throws -> CoreAudioVolumeObservationState.Registration {
        try lock.withLock {
            state.listenerAddAttempts += 1
            if state.listenerAddAttempts == state.listenerAddFailureAt { throw AudioVolumeIssue.listenerUnavailable }
        }
        let delivery = AudioVolumeListenerDelivery(changed)
        let queue = DispatchQueue(label: "test.volume.listener.\(UUID().uuidString)")
        // Constructing a token has no HAL effect. This fake never calls its
        // register/remove methods; their native identity is tested separately
        // through injected operations in THVolumeListenerTokenTests.m.
        let token = THVolumeListenerToken(object: object, address: address, queue: queue) { _, _ in delivery.signal() }
        let registration = CoreAudioVolumeObservationState.Registration(
            object: object, address: address, queue: queue, token: token, delivery: delivery)
        lock.withLock { state.registrations.append(registration) }
        return registration
    }

    func removeListener(_ registration: CoreAudioVolumeObservationState.Registration) -> OSStatus {
        lock.withLock {
            let original = state.registrations.first { $0.delivery === registration.delivery }
            let matches = original.map {
                $0.object == registration.object && VolumeProperty($0.address) == VolumeProperty(registration.address) &&
                    $0.queue === registration.queue && $0.token === registration.token
            } ?? false
            state.listenerRemovalMatches.append(matches)
            return state.listenerRemovalStatuses.isEmpty ? noErr : state.listenerRemovalStatuses.removeFirst()
        }
    }

    func fireListener(at index: Int) {
        let registration = lock.withLock { state.registrations[index] }
        registration.delivery.signal()
    }
}
