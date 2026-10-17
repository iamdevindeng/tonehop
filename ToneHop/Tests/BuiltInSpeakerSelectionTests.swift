import CoreAudio
import IOKit.audio
import XCTest
@testable import ToneHop

final class BuiltInSpeakerSelectionTests: XCTestCase {
    func testExactSpeakerTerminalWinsOverHeadphonesRegardlessOfDisplayName() throws {
        let speaker = candidate(uid: "opaque-speaker", name: "自定义名称")
        let headphones = candidate(uid: "opaque-headphones", name: "Mac 自带扬声器",
                                   terminals: [kAudioStreamTerminalTypeHeadphones])
        let selected = try BuiltInSpeakerSelection.resolve([headphones, speaker],
                                                           deviceUIDs: ["opaque-headphones", "opaque-speaker"])
        XCTAssertEqual(selected, speaker.device)
    }

    func testBuiltInTransportAndSpeakerPresentationCannotIdentifyHeadphones() {
        let headphones = candidate(terminals: [kAudioStreamTerminalTypeHeadphones])
        XCTAssertEqual(headphones.device.transport, .speaker)
        XCTAssertThrowsError(try resolve([headphones]))
    }

    func testIOKitSpeakerTerminalIsRecognizedWithoutUsingNameOrUIDConventions() throws {
        let speaker = candidate(uid: "opaque-device", name: "Unrelated display name", terminals: [UInt32(OUTPUT_SPEAKER)])
        let headphones = candidate(uid: "another-device", name: "Mac 自带扬声器", terminals: [UInt32(OUTPUT_HEADPHONES)])
        XCTAssertEqual(try resolve([headphones, speaker]), speaker.device)
        XCTAssertThrowsError(try resolve([headphones]))
    }

    func testIOKitTerminalProofRejectsUnknownAndMixedNonSpeakerOutputs() {
        for terminal in [OUTPUT_UNDEFINED, OUTPUT_HEADPHONES, EXTERNAL_LINE_CONNECTOR] {
            XCTAssertThrowsError(try resolve([candidate(terminals: [UInt32(OUTPUT_SPEAKER), UInt32(terminal)])]))
        }
        XCTAssertThrowsError(try resolve([candidate(terminals: [UInt32(OUTPUT_UNDEFINED)])]))
    }

    func testSpeakerAndLFEAcceptBothPublicTerminalEncodings() throws {
        for terminals in [[UInt32(OUTPUT_SPEAKER), UInt32(OUTPUT_LOW_FREQUENCY_EFFECTS_SPEAKER)],
                          [UInt32(OUTPUT_SPEAKER), kAudioStreamTerminalTypeLFESpeaker],
                          [kAudioStreamTerminalTypeSpeaker, UInt32(OUTPUT_LOW_FREQUENCY_EFFECTS_SPEAKER)]] {
            let speaker = candidate(terminals: terminals)
            XCTAssertEqual(try resolve([speaker]), speaker.device)
        }
        XCTAssertThrowsError(try resolve([candidate(terminals: [UInt32(OUTPUT_LOW_FREQUENCY_EFFECTS_SPEAKER)])]))
    }

    func testExternalSpeakerCannotSatisfyBuiltInSpeakerRequest() {
        for transport in [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth,
                          kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeVirtual] {
            XCTAssertThrowsError(try resolve([candidate(transport: transport)]))
        }
    }

    func testNoSpeakerAndTwoVerifiedSpeakersFailWithoutChoosingByOrder() {
        XCTAssertThrowsError(try resolve([]))
        let first = candidate(uid: "one")
        let second = candidate(uid: "two")
        XCTAssertThrowsError(try resolve([first, second]))
        XCTAssertThrowsError(try resolve([second, first]))
    }

    func testDuplicateUIDAnywhereInHardwareDirectoryRejectsSpeaker() {
        let speaker = candidate()
        XCTAssertThrowsError(try BuiltInSpeakerSelection.resolve([speaker], deviceUIDs: ["speaker", "speaker"]))
        XCTAssertThrowsError(try BuiltInSpeakerSelection.resolve([speaker], deviceUIDs: ["another-device"]))
    }

    func testUnknownTerminalDoesNotPermitSelectingAnotherCandidateByElimination() {
        let known = candidate(uid: "known")
        for terminals in [[], [kAudioStreamTerminalTypeUnknown], [UInt32.max]] {
            let unknown = candidate(uid: "unknown", terminals: terminals)
            XCTAssertThrowsError(try resolve([unknown]))
            XCTAssertThrowsError(try resolve([known, unknown]))
        }
    }

    func testMixedSpeakerAndHeadphoneOrLineStreamsAreNotAnExclusiveSpeakerTarget() {
        for other in [kAudioStreamTerminalTypeHeadphones, kAudioStreamTerminalTypeLine] {
            XCTAssertThrowsError(try resolve([candidate(terminals: [kAudioStreamTerminalTypeSpeaker, other])]))
        }
    }

    func testSpeakerMayIncludeLowFrequencySpeakerButLFEDoesNotReplaceSpeakerProof() throws {
        let speaker = candidate(terminals: [kAudioStreamTerminalTypeSpeaker, kAudioStreamTerminalTypeLFESpeaker])
        XCTAssertEqual(try resolve([speaker]), speaker.device)
        XCTAssertThrowsError(try resolve([candidate(terminals: [kAudioStreamTerminalTypeLFESpeaker])]))
    }

    func testUnavailableHiddenInputOnlyOrIneligibleDevicesCannotBeExitTargets() {
        let invalid = [candidate(alive: false), candidate(eligible: false),
                       candidate(hidden: true), candidate(channels: 0)]
        for device in invalid { XCTAssertThrowsError(try resolve([device])) }
        XCTAssertThrowsError(try resolve([candidate(direction: 1)]))
    }

    func testRepeatedStreamObjectCannotCreateAdditionalSpeakerEvidence() {
        let base = candidate()
        let repeated = BuiltInSpeakerSelection.Candidate(
            objectID: base.objectID, device: base.device, transportType: base.transportType,
            alive: base.alive, canBeDefaultOutput: base.canBeDefaultOutput, hidden: base.hidden,
            outputChannelCount: base.outputChannelCount, streams: [base.streams[0], base.streams[0]]
        )
        XCTAssertThrowsError(try resolve([repeated]))
    }

    func testProtocolDefaultDoesNotGuessSpeakerFromSnapshot() async {
        let hardware = UnsupportedSpeakerHardware()
        do {
            _ = try await hardware.builtInSpeaker()
            XCTFail("A provider without terminal evidence must explicitly reject the request.")
        } catch {
            guard case AudioServiceError.unavailable = error else {
                return XCTFail("Expected an explicit unsupported capability, got \(error)")
            }
        }
        let reads = await hardware.snapshotReads
        XCTAssertEqual(reads, 0, "The default must not guess from display classification or row order.")
    }

    func testTransientReadFailureClassificationIsLimitedToDisappearingHALObjects() {
        for status in [kAudioHardwareBadObjectError, kAudioHardwareBadDeviceError] {
            XCTAssertTrue(AudioHardwareReadFailure.isTransient(AudioServiceError.system(operation: "fixture", status: status)))
        }
        for status in [kAudioHardwareUnknownPropertyError, kAudioHardwareBadPropertySizeError,
                       kAudioHardwareIllegalOperationError] {
            XCTAssertFalse(AudioHardwareReadFailure.isTransient(AudioServiceError.system(operation: "fixture", status: status)))
        }
        XCTAssertFalse(AudioHardwareReadFailure.isTransient(CancellationError()))
        XCTAssertFalse(AudioHardwareReadFailure.isTransient(AudioServiceError.ambiguousIdentity))
    }

    @MainActor
    func testStableInventoryRetriesDisappearingObjectWithAFreshCompletePair() async throws {
        let previous = inventory(uid: "previous")
        let current = inventory(uid: "current")
        for status in [kAudioHardwareBadObjectError, kAudioHardwareBadDeviceError] {
            var reads = 0
            var waits = 0
            let result = try await BuiltInSpeakerSelection.readStableInventory(read: {
                reads += 1
                if reads == 1 { return previous }
                if reads == 2 { throw AudioServiceError.system(operation: "fixture", status: status) }
                return current
            }, wait: { waits += 1 })
            XCTAssertEqual(result, current)
            XCTAssertEqual(reads, 4)
            XCTAssertEqual(waits, 1)
        }
    }

    @MainActor
    func testStableInventoryRetriesChangedDirectoryBeforeResolving() async throws {
        let previous = inventory(uid: "previous")
        let current = inventory(uid: "current")
        var reads = 0
        var waits = 0
        let result = try await BuiltInSpeakerSelection.readStableInventory(read: {
            reads += 1
            return reads == 1 ? previous : current
        }, wait: { waits += 1 })
        XCTAssertEqual(result, current)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(waits, 1)
    }

    @MainActor
    func testStableInventoryHasBoundedRetriesForMissingObjectsAndContinualChanges() async {
        let first = inventory(uid: "first")
        let second = inventory(uid: "second")
        for missingObject in [true, false] {
            var reads = 0
            var waits = 0
            do {
                _ = try await BuiltInSpeakerSelection.readStableInventory(read: {
                    reads += 1
                    if missingObject { throw AudioServiceError.system(operation: "fixture", status: kAudioHardwareBadObjectError) }
                    return reads.isMultiple(of: 2) ? second : first
                }, wait: { waits += 1 })
                XCTFail("An unstable directory must not produce a speaker identity.")
            } catch {
                guard case AudioHardwareReadFailure.unstableInventory = error else {
                    return XCTFail("Expected typed transient exhaustion, got \(error)")
                }
                XCTAssertTrue(error.localizedDescription.contains(expectedLocalized("Audio devices are still changing", "音频设备仍在变化")))
            }
            XCTAssertEqual(reads, missingObject ? 4 : 8)
            XCTAssertEqual(waits, 3)
        }
    }

    @MainActor
    func testStableInventoryDoesNotRetryOrReplaceNonTransientPropertyErrors() async {
        var reads = 0
        var waits = 0
        do {
            _ = try await BuiltInSpeakerSelection.readStableInventory(read: {
                reads += 1
                throw AudioServiceError.system(operation: "original property", status: kAudioHardwareUnknownPropertyError)
            }, wait: { waits += 1 })
            XCTFail("A real property failure must escape immediately.")
        } catch {
            guard case let AudioServiceError.system(operation, status) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(operation, "original property")
            XCTAssertEqual(status, kAudioHardwareUnknownPropertyError)
        }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(waits, 0)
    }

    @MainActor
    func testStableInventoryStopsAfterShutdownDuringRetryWait() async {
        let signal = AudioShutdownSignal()
        var reads = 0
        var waits = 0
        do {
            _ = try await BuiltInSpeakerSelection.readStableInventory(read: {
                reads += 1
                throw AudioServiceError.system(operation: "fixture", status: kAudioHardwareBadObjectError)
            }, checkRunning: { try signal.checkRunning() }, wait: {
                waits += 1
                signal.begin()
            })
            XCTFail("Shutdown must stop directory retries.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(waits, 1)
    }

    @MainActor
    func testStableInventoryStopsAfterCancellationDuringRetryWait() async {
        var reads = 0
        var waits = 0
        do {
            _ = try await BuiltInSpeakerSelection.readStableInventory(read: {
                reads += 1
                throw AudioServiceError.system(operation: "fixture", status: kAudioHardwareBadObjectError)
            }, wait: {
                waits += 1
                throw CancellationError()
            })
            XCTFail("A cancelled wait must not issue further reads.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(waits, 1)
    }

    private func inventory(uid: String) -> BuiltInSpeakerSelection.Inventory {
        let speaker = candidate(uid: uid)
        return BuiltInSpeakerSelection.Inventory(
            identities: [.init(objectID: speaker.objectID, uid: uid, transportType: speaker.transportType)],
            candidates: [speaker]
        )
    }

    private func resolve(_ candidates: [BuiltInSpeakerSelection.Candidate]) throws -> AudioDevice {
        let uids = candidates.compactMap { candidate -> String? in
            guard case let .coreAudio(uid) = candidate.device.backend else { return nil }
            return uid
        }
        return try BuiltInSpeakerSelection.resolve(candidates, deviceUIDs: uids)
    }

    private func candidate(uid: String = "speaker", name: String = "Fixture",
                           transport: UInt32 = kAudioDeviceTransportTypeBuiltIn,
                           alive: Bool = true, eligible: Bool = true, hidden: Bool = false,
                           channels: UInt32 = 2, direction: UInt32 = 0,
                           terminals: [UInt32] = [kAudioStreamTerminalTypeSpeaker]) -> BuiltInSpeakerSelection.Candidate {
        BuiltInSpeakerSelection.Candidate(
            objectID: 100,
            device: AudioDevice(id: "hal:\(uid)", name: name, transport: .speaker, backend: .coreAudio(uid: uid)),
            transportType: transport, alive: alive, canBeDefaultOutput: eligible, hidden: hidden,
            outputChannelCount: channels,
            streams: terminals.enumerated().map {
                BuiltInSpeakerSelection.Stream(objectID: UInt32($0.offset + 200), direction: direction, terminalType: $0.element)
            }
        )
    }
}

private actor UnsupportedSpeakerHardware: AudioHardwareProviding {
    private(set) var snapshotReads = 0
    nonisolated func beginShutdown() {}
    func snapshot() -> CoreAudioSnapshot {
        snapshotReads += 1
        return CoreAudioSnapshot(devices: [], currentDeviceID: nil, systemSoundDeviceID: nil, warnings: [])
    }
    func select(uid: String) {}
    func observeChanges(_ changed: @escaping @Sendable () -> Void) {}
    func stopObserving() {}
}
