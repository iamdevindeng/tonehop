import AppKit
import SwiftUI

/// AppKit retains slider tracking, keyboard and accessibility behavior. The
/// bridge changes only presentation and forwards value/editing events.
@MainActor
struct NativeVolumeSlider: NSViewRepresentable {
    let value: Double
    let isEnabled: Bool
    let label: String
    let valueDescription: String
    let hint: String
    let onValueChange: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> VolumeSliderControl {
        let slider = VolumeSliderControl()
        configure(slider)
        return slider
    }

    func updateNSView(_ slider: VolumeSliderControl, context: Context) { configure(slider) }

    private func configure(_ slider: VolumeSliderControl) {
        slider.onValueChange = onValueChange
        slider.onEditingChanged = onEditingChanged
        slider.isEnabled = isEnabled
        if !slider.isDragging { slider.doubleValue = value }
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValueDescription(valueDescription)
        slider.setAccessibilityHelp(hint)
        slider.toolTip = hint
        slider.needsDisplay = true
    }

    static func dismantleNSView(_ slider: VolumeSliderControl, coordinator: ()) {
        slider.onValueChange = nil
        slider.onEditingChanged = nil
    }
}

@MainActor
final class VolumeSliderControl: NSSlider {
    var onValueChange: ((Double) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?
    private(set) var isDragging = false
    private var isHovered = false
    private var hoverArea: NSTrackingArea?

    var showsKnob: Bool {
        isEnabled && (isHovered || isDragging || window?.firstResponder === self)
    }

    init() {
        super.init(frame: .zero)
        cell = VolumeSliderCell()
        sliderType = .linear
        isVertical = false
        numberOfTickMarks = 0
        minValue = 0
        maxValue = 1
        altIncrementValue = 0.05
        isContinuous = true
        controlSize = .small
        focusRingType = .none
        target = self
        action = #selector(valueChanged)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isDragging = true
        needsDisplay = true
        onEditingChanged?(true)
        defer {
            isDragging = false
            onEditingChanged?(false)
            needsDisplay = true
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        // A custom cell and an explicitly focusable control must deliver arrow
        // edits even when NSSlider's inherited handler makes no change. Keep
        // AppKit's standard key-binding interpretation instead of raw key codes.
        let arrows: Set<String> = ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}"]
        if let key = event.charactersIgnoringModifiers, arrows.contains(key),
           event.modifierFlags.intersection([.command, .control, .shift]).isEmpty {
            interpretKeyEvents([event])
        } else {
            super.keyDown(with: event)
        }
    }

    override func moveLeft(_ sender: Any?) { step(-0.01) }
    override func moveRight(_ sender: Any?) { step(0.01) }
    override func moveDown(_ sender: Any?) { step(-0.01) }
    override func moveUp(_ sender: Any?) { step(0.01) }
    override func moveBackward(_ sender: Any?) { step(-0.01) }
    override func moveForward(_ sender: Any?) { step(0.01) }
    override func moveWordLeft(_ sender: Any?) { step(-altIncrementValue) }
    override func moveWordRight(_ sender: Any?) { step(altIncrementValue) }
    override func moveWordBackward(_ sender: Any?) { step(-altIncrementValue) }
    override func moveWordForward(_ sender: Any?) { step(altIncrementValue) }
    override func moveToBeginningOfParagraph(_ sender: Any?) { step(-altIncrementValue) }
    override func moveToEndOfParagraph(_ sender: Any?) { step(altIncrementValue) }

    private func step(_ amount: Double) {
        guard isEnabled else { return }
        let next = min(maxValue, max(minValue, doubleValue + amount))
        guard next != doubleValue else { return }
        doubleValue = next
        needsDisplay = true
        _ = sendAction(action, to: target)
    }

    @objc private func valueChanged() {
        guard isEnabled else { return }
        if isDragging {
            onValueChange?(doubleValue)
        } else {
            // Keyboard and accessibility actions are complete edits rather than
            // pointer drags, so the Store receives their final value immediately.
            onEditingChanged?(true)
            onValueChange?(doubleValue)
            onEditingChanged?(false)
        }
    }
}

@MainActor
private final class VolumeSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        let path = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
        NSColor.labelColor.withAlphaComponent(isEnabled ? 0.23 : 0.12).setFill()
        path.fill()
        let fraction = CGFloat(min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))))
        if fraction > 0 {
            NSColor.white.withAlphaComponent(isEnabled ? 0.95 : 0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                           width: track.width * fraction, height: track.height),
                         xRadius: 2, yRadius: 2).fill()
        }
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        guard (controlView as? VolumeSliderControl)?.showsKnob == true else { return }
        let circle = NSBezierPath(ovalIn: NSRect(x: knobRect.midX - 7, y: knobRect.midY - 7,
                                               width: 14, height: 14))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.labelColor.withAlphaComponent(0.1).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
    }
}
