import XCTest
@testable import ToneHop

final class StatusBarVolumePresentationTests: XCTestCase {
    func testConfirmedPercentagesUseReadbackAndExistingRounding() {
        let cases: [(Float, Int)] = [(0, 0), (0.004, 0), (0.656, 66), (1, 100)]
        for (value, percent) in cases {
            let presentation = makePresentation(value: value)
            XCTAssertEqual(presentation.content, .percentage(percent))
            XCTAssertEqual(presentation.help, expectedLocalized("Volume \(percent)%", "音量 \(percent)%"))
        }
    }

    func testSliderDraftAndWriteInProgressDoNotReplaceConfirmedReadback() {
        var state = makeState(value: 0.25)
        state.draftValue = 0.85
        state.isWriting = true
        state.issue = .writeFailed(-17)
        let presentation = project(state)
        XCTAssertEqual(presentation.content, .percentage(25))
        XCTAssertEqual(presentation.help, expectedLocalized("Volume 25%", "音量 25%"))
    }

    func testBackgroundReadKeepsSameIdentityConfirmedValue() {
        var state = makeState(value: 0.65)
        state.isReading = true
        XCTAssertEqual(project(state).content, .percentage(65))
    }

    func testFullMuteShowsIconWithAndWithoutReadableVolume() {
        let readable = makePresentation(value: 0.65, mute: .muted)
        XCTAssertEqual(readable.content, .muted)
        XCTAssertEqual(readable.help, expectedLocalized("Muted; volume setting 65%", "已静音；设定音量 65%"))

        let unreadable = makePresentation(value: nil, capability: .unavailable(.unsupported), mute: .muted)
        XCTAssertEqual(unreadable.content, .muted)
        XCTAssertEqual(unreadable.help, expectedLocalized("Muted; volume unavailable", "已静音；音量不可读"))
        XCTAssertEqual(makePresentation(value: 0, mute: .muted).content, .muted)
    }

    func testPartialMuteDoesNotBecomeFullMuteIcon() {
        let presentation = makePresentation(value: 0.65, mute: .mixed)
        XCTAssertEqual(presentation.content, .percentage(65))
        XCTAssertEqual(presentation.help, expectedLocalized(
            "Volume 65%\nSome channels are muted", "音量 65%\n部分声道已静音"))

        let unreadable = makePresentation(value: nil, capability: .unavailable(.readOnly), mute: .mixed)
        XCTAssertEqual(unreadable.content, .unavailable)
        XCTAssertTrue(unreadable.help.contains(expectedLocalized("Some channels are muted", "部分声道已静音")))
    }

    func testUnknownOrUnsupportedMuteDoesNotSuppressReadableScalarOrInferMuteFromZero() {
        let cases: [(AudioVolumeMuteState, String, String)] = [
            (.unknown, "Mute status is unconfirmed", "静音状态待确认"),
            (.unsupported, "Mute status is unavailable", "无法读取静音状态")
        ]
        for (mute, english, chinese) in cases {
            let presentation = makePresentation(value: 0, mute: mute)
            XCTAssertEqual(presentation.content, .percentage(0))
            XCTAssertEqual(presentation.help, expectedLocalized(
                "Volume 0%\n\(english)", "音量 0%\n\(chinese)"))
        }
    }

    func testReadOnlyAndUnimplementedControlsStillShowTheirReadableVolume() {
        for issue: AudioVolumeIssue in [.readOnly, .implementationGap] {
            let presentation = makePresentation(value: 0.4, capability: .unavailable(issue))
            XCTAssertEqual(presentation.content, .percentage(40))
            XCTAssertTrue(presentation.help.hasPrefix(expectedLocalized("Volume 40%", "音量 40%")))
            XCTAssertTrue(presentation.help.contains(issue.localizedDescription))
        }
        var unavailableForSwitching = device
        unavailableForSwitching.isAvailable = false
        XCTAssertEqual(project(makeState(value: 0.4), device: unavailableForSwitching).content, .percentage(40))
    }

    func testMissingScalarAndInvalidScalarsCannotProducePercentages() {
        let missing = makePresentation(value: nil, capability: .unavailable(.readOnly))
        XCTAssertEqual(missing.content, .unavailable)
        XCTAssertEqual(missing.help, expectedLocalized("Volume unavailable", "音量不可读"))

        for value: Float in [.nan, .infinity, -.infinity, -0.1, 1.1] {
            for mute: AudioVolumeMuteState in [.unmuted, .muted] {
                let invalid = makePresentation(value: value, mute: mute)
                XCTAssertEqual(invalid.content, .unavailable)
                XCTAssertEqual(invalid.help, AudioVolumeIssue.invalidReadback.localizedDescription)
            }
        }
    }

    func testUnknownCurrentAndMissingRowHaveDistinctHelp() {
        let unknownCurrent = StatusBarVolumePresentation(device: nil, state: makeState(value: 0.65),
                                                        isPaused: false, isClosed: false)
        XCTAssertEqual(unknownCurrent.content, .unavailable)
        XCTAssertEqual(unknownCurrent.help, expectedLocalized(
            "Volume unavailable until the current output is confirmed", "确认当前输出后才能显示音量"))

        let missingRow = StatusBarVolumePresentation(device: device, state: nil, isPaused: false, isClosed: false)
        XCTAssertEqual(missingRow.content, .unavailable)
        XCTAssertEqual(missingRow.help, expectedLocalized("Reading volume…", "正在读取音量…"))
    }

    func testReadingUnsupportedAndFailedReadHaveDistinctUnavailableDescriptions() {
        let target = makeTarget()
        let reading = AudioVolumeRowState(deviceID: device.id, target: target, isReading: true)
        XCTAssertEqual(project(reading).help, expectedLocalized("Reading volume…", "正在读取音量…"))

        let unsupported = makePresentation(value: nil, capability: .unavailable(.unsupported))
        XCTAssertEqual(unsupported.content, .unavailable)
        XCTAssertEqual(unsupported.help, expectedLocalized(
            "This device does not provide a system volume value", "此设备不提供系统音量值"))

        let readFailed = AudioVolumeRowState(deviceID: device.id, target: target, issue: .readFailed(-72))
        XCTAssertEqual(project(readFailed).content, .unavailable)
        XCTAssertEqual(project(readFailed).help, AudioVolumeIssue.readFailed(-72).localizedDescription)
    }

    func testPauseAndClosureHideRetainedVolumeAndMuteEvidence() {
        for mute: AudioVolumeMuteState in [.unmuted, .muted] {
            let state = makeState(value: 0.65, mute: mute)
            let paused = StatusBarVolumePresentation(device: device, state: state, isPaused: true, isClosed: false)
            XCTAssertEqual(paused.content, .unavailable)
            XCTAssertEqual(paused.help, expectedLocalized("Confirming volume…", "正在确认音量…"))

            let closed = StatusBarVolumePresentation(device: device, state: state, isPaused: true, isClosed: true)
            XCTAssertEqual(closed.content, .unavailable)
            XCTAssertEqual(closed.help, AudioVolumeIssue.closed.localizedDescription)
        }
    }

    func testDifferentRowsTargetsAndBackendsCannotBorrowVolumeEvidence() {
        let target = makeTarget()
        let snapshot = AudioVolumeSnapshot(target: target, value: 0.65, capability: .writable(.main), mute: .muted)
        let wrongRow = AudioVolumeRowState(deviceID: "another-row", target: target, snapshot: snapshot)
        let noTarget = AudioVolumeRowState(deviceID: device.id, snapshot: snapshot, issue: .identityUnconfirmed)
        let wrongIDTarget = AudioVolumeTarget(deviceID: "another-target", uid: target.uid)
        let wrongUIDTarget = AudioVolumeTarget(deviceID: device.id, uid: "another-uid")
        let emptyUIDTarget = AudioVolumeTarget(deviceID: device.id, uid: "")
        let unexpectedReceiver = AudioVolumeTarget(deviceID: device.id, uid: target.uid, receiverID: "receiver")
        for state in [wrongRow, noTarget] + [wrongIDTarget, wrongUIDTarget, emptyUIDTarget, unexpectedReceiver].map({
            AudioVolumeRowState(deviceID: device.id, target: $0,
                snapshot: AudioVolumeSnapshot(target: $0, value: 0.65, capability: .writable(.main), mute: .muted))
        }) {
            XCTAssertEqual(project(state).content, .unavailable)
            XCTAssertEqual(project(state).help, expectedLocalized(
                "Volume unavailable until the device is confirmed", "确认设备后才能显示音量"))
        }
        let unknownBackend = AudioDevice(id: device.id, name: device.name, transport: .unknown, backend: .unavailable)
        XCTAssertEqual(project(makeState(value: 0.65), device: unknownBackend).content, .unavailable)
    }

    func testTargetAndServiceGenerationMismatchesRejectEvenMuteOnlyReadback() {
        let target = makeTarget(serviceGeneration: UUID())
        let otherTargets = [
            AudioVolumeTarget(deviceID: target.deviceID, uid: target.uid,
                              generation: UUID(), serviceGeneration: target.serviceGeneration),
            AudioVolumeTarget(deviceID: target.deviceID, uid: target.uid,
                              generation: target.generation, serviceGeneration: UUID())
        ]
        for other in otherTargets {
            let state = AudioVolumeRowState(deviceID: device.id, target: target,
                snapshot: AudioVolumeSnapshot(target: other, value: nil, capability: .unavailable(.unsupported), mute: .muted))
            XCTAssertEqual(project(state).content, .unavailable)
        }
    }

    func testPrivateReceiverRequiresTheSameExplicitAssociation() {
        let receiver = AudioDevice(id: "receiver:fixture", name: "Same name", transport: .airplay,
                                   backend: .privateRoute(identifier: "fixture"))
        for identifier in ["fixture", "other-receiver"] {
            let target = AudioVolumeTarget(deviceID: receiver.id, uid: "fixture-stream", receiverID: identifier)
            let state = AudioVolumeRowState(deviceID: receiver.id, target: target,
                snapshot: AudioVolumeSnapshot(target: target, value: 0.65, capability: .writable(.main), mute: .unmuted))
            XCTAssertEqual(project(state, device: receiver).content,
                           identifier == "fixture" ? .percentage(65) : .unavailable)
        }
    }

    private var device: AudioDevice {
        AudioDevice(id: "hal:fixture-output", name: "Fixture output", transport: .speaker,
                    backend: .coreAudio(uid: "fixture-output"))
    }

    private func makeTarget(serviceGeneration: UUID? = nil) -> AudioVolumeTarget {
        AudioVolumeTarget(deviceID: device.id, uid: "fixture-output", serviceGeneration: serviceGeneration)
    }

    private func makeState(value: Float?, capability: AudioVolumeCapability = .writable(.main),
                           mute: AudioVolumeMuteState = .unmuted) -> AudioVolumeRowState {
        let target = makeTarget()
        return AudioVolumeRowState(deviceID: device.id, target: target,
            snapshot: AudioVolumeSnapshot(target: target, value: value, capability: capability, mute: mute))
    }

    private func makePresentation(value: Float?, capability: AudioVolumeCapability = .writable(.main),
                                  mute: AudioVolumeMuteState = .unmuted) -> StatusBarVolumePresentation {
        project(makeState(value: value, capability: capability, mute: mute))
    }

    private func project(_ state: AudioVolumeRowState, device: AudioDevice? = nil) -> StatusBarVolumePresentation {
        StatusBarVolumePresentation(device: device ?? self.device, state: state, isPaused: false, isClosed: false)
    }
}
