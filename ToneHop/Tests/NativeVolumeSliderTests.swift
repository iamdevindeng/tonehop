import AppKit
import XCTest
@testable import ToneHop

@MainActor
final class NativeVolumeSliderTests: XCTestCase {
    func testNativeActionDeliversOneCompleteEditWithActualControlValue() {
        let slider = VolumeSliderControl()
        var events: [String] = []
        slider.onEditingChanged = { events.append($0 ? "begin" : "end") }
        slider.onValueChange = { events.append("value:\($0)") }
        slider.doubleValue = 0.65

        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        XCTAssertEqual(events, ["begin", "value:0.65", "end"])
    }

    func testKeyboardFocusKeepsKnobVisibleUntilFocusLeaves() {
        let (window, slider) = controlInWindow()
        defer { window.close() }
        XCTAssertFalse(slider.showsKnob)
        XCTAssertTrue(window.makeFirstResponder(slider))
        XCTAssertTrue(slider.showsKnob)
        window.makeFirstResponder(nil)
        XCTAssertFalse(slider.showsKnob)
    }

    func testHoverShowsOnlyEnabledKnobAndLeavingRestoresQuietTrack() throws {
        let slider = VolumeSliderControl()
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, trackingNumber: 0, userData: nil))
        XCTAssertFalse(slider.showsKnob)
        slider.mouseEntered(with: event)
        XCTAssertTrue(slider.showsKnob)
        slider.isEnabled = false
        XCTAssertFalse(slider.showsKnob)
        slider.isEnabled = true
        slider.mouseExited(with: event)
        XCTAssertFalse(slider.showsKnob)
    }

    func testNativeArrowKeyChangesValueAndCompletesEditing() throws {
        let (window, slider) = controlInWindow()
        defer { window.close() }
        var edited: [Bool] = [], values: [Double] = []
        slider.doubleValue = 0.4
        slider.onEditingChanged = { edited.append($0) }
        slider.onValueChange = { values.append($0) }
        XCTAssertTrue(window.makeFirstResponder(slider))

        slider.keyDown(with: try arrowEvent(window: window))

        XCTAssertGreaterThan(slider.doubleValue, 0.4)
        XCTAssertEqual(edited, [true, false])
        XCTAssertEqual(values, [slider.doubleValue])
        XCTAssertFalse(slider.isDragging)
    }

    func testDisabledControlRejectsKeyboardAndActionSubmission() throws {
        let (window, slider) = controlInWindow()
        defer { window.close() }
        var submissions = 0
        slider.onEditingChanged = { _ in submissions += 1 }
        slider.onValueChange = { _ in submissions += 1 }
        slider.doubleValue = 0.4
        slider.isEnabled = false

        slider.keyDown(with: try arrowEvent(window: window))
        _ = slider.sendAction(slider.action, to: slider.target)

        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(slider.doubleValue, 0.4)
        XCTAssertFalse(slider.acceptsFirstResponder)
    }

    func testArrowKeyClampsAtMaximumAndDoesNotSubmitAnUnchangedValue() throws {
        let (window, slider) = controlInWindow()
        defer { window.close() }
        var edited: [Bool] = [], values: [Double] = []
        slider.doubleValue = 0.995
        slider.onEditingChanged = { edited.append($0) }
        slider.onValueChange = { values.append($0) }
        XCTAssertTrue(window.makeFirstResponder(slider))

        slider.keyDown(with: try arrowEvent(window: window))
        slider.keyDown(with: try arrowEvent(window: window))

        XCTAssertEqual(slider.doubleValue, 1)
        XCTAssertEqual(edited, [true, false])
        XCTAssertEqual(values, [1])
    }

    func testOptionArrowUsesLargerStepThroughStandardKeyBinding() throws {
        let (window, slider) = controlInWindow()
        defer { window.close() }
        var values: [Double] = []
        slider.doubleValue = 0.4
        slider.onValueChange = { values.append($0) }
        XCTAssertTrue(window.makeFirstResponder(slider))

        slider.keyDown(with: try arrowEvent(window: window, modifiers: .option))

        XCTAssertEqual(slider.doubleValue, 0.45, accuracy: 0.00001)
        XCTAssertEqual(values, [slider.doubleValue])
    }

    func testConfirmedZeroKeepsTrackWhileUnsupportedAndUnknownDoNot() {
        let target = AudioVolumeTarget(deviceID: "hal:volume-ui", uid: "volume-ui")
        var state = AudioVolumeRowState(deviceID: target.deviceID, target: target,
            snapshot: AudioVolumeSnapshot(target: target, value: 0, capability: .writable(.main)))
        XCTAssertTrue(DeviceVolumeView.showsTrack(state: state))
        state.snapshot = AudioVolumeSnapshot(target: target, value: 0, capability: .unavailable(.unsupported))
        XCTAssertFalse(DeviceVolumeView.showsTrack(state: state))
        state.snapshot = nil
        XCTAssertFalse(DeviceVolumeView.showsTrack(state: state))
        XCTAssertFalse(DeviceVolumeView.showsTrack(state: nil))
    }

    private func controlInWindow() -> (NSWindow, VolumeSliderControl) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let slider = VolumeSliderControl()
        slider.frame = NSRect(x: 20, y: 20, width: 200, height: 24)
        window.contentView?.addSubview(slider)
        return (window, slider)
    }

    private func arrowEvent(window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
            charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
    }
}
