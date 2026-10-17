import XCTest
@testable import ToneHop

@MainActor
final class AudioFeedbackPresentationTests: XCTestCase {
    private let hint = RetainedRouteCapability.preparationHint

    func testUnavailableAirPlayPreparationGuidanceAppearsOnlyBesideDevice() {
        let receiver = device(reason: hint)
        XCTAssertEqual(DeviceRowView.unavailableHint(for: receiver, isCurrent: false), hint)
        XCTAssertNil(AudioFeedbackView.visibleCatalogWarning(hint, devices: [receiver], currentDeviceID: nil))
    }

    func testCombinedWarningsKeepOtherMessagesInOrderAndRemoveRepeatedRowHint() {
        let first = "系统状态通知暂不可用，正在定期刷新。"
        let last = "网络路由与系统默认输出尚未一致，当前输出待确认。"
        let warning = [first, hint, last, hint].joined(separator: "\n")
        XCTAssertEqual(AudioFeedbackView.visibleCatalogWarning(warning, devices: [device(reason: hint)],
                                                              currentDeviceID: nil),
                       [first, last].joined(separator: "\n"))
    }

    func testWarningRemainsWhenMatchingRowDoesNotDisplayHint() {
        let unavailable = device(reason: hint)
        let cases: [(devices: [AudioDevice], current: String?)] = [
            ([unavailable], unavailable.id),
            ([device(available: true, reason: hint)], nil),
            ([device(transport: .speaker, reason: hint)], nil),
            ([], nil),
        ]
        for item in cases {
            XCTAssertEqual(AudioFeedbackView.visibleCatalogWarning(hint, devices: item.devices,
                                                                  currentDeviceID: item.current), hint)
        }
    }

    func testMultilineHintIsRemovedAsAWholeWithoutRemovingAnUnrelatedSharedLine() {
        let firstLine = "设备暂不可用。"
        let multilineHint = firstLine + "\n请在系统中重新选择此设备。"
        let warning = firstLine + "\n其他设备需要检查。\n" + multilineHint
        XCTAssertEqual(AudioFeedbackView.visibleCatalogWarning(warning, devices: [device(reason: multilineHint)],
                                                              currentDeviceID: nil),
                       firstLine + "\n其他设备需要检查。")
    }

    func testPreparationGuidanceUsesLocalizedCompactCopyAndKeepsDetailedHelp() {
        let receiver = device(reason: hint)
        XCTAssertEqual(DeviceRowView.unavailableHintText(for: hint),
                       expectedLocalized("Select once in system Sound settings", "先在系统「声音」中选择一次此设备"))
        XCTAssertEqual(DeviceRowView.unavailableHintHeight(for: hint), DeviceRowView.issueHeight)
        XCTAssertEqual(DeviceRowView.unavailableHint(for: receiver, isCurrent: false), hint)
        XCTAssertNil(AudioFeedbackView.visibleCatalogWarning(hint, devices: [receiver], currentDeviceID: nil))
    }

    func testUnrelatedDiagnosticKeepsItsOriginalTextAndHeight() {
        let diagnostic = "Receiver 卧室: %@ / state unavailable"
        XCTAssertEqual(DeviceRowView.unavailableHintText(for: diagnostic), diagnostic)
        XCTAssertEqual(DeviceRowView.unavailableHintHeight(for: diagnostic), 60)
    }

    private func device(transport: AudioTransport = .airplay, available: Bool = false, reason: String) -> AudioDevice {
        AudioDevice(id: "route:bedroom", name: "Bedroom", transport: transport,
                    backend: .privateRoute(identifier: "bedroom"), isAvailable: available, unavailableReason: reason)
    }
}
