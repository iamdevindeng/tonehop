import AppKit

/// Draws one template image for the existing native status button. AppKit owns
/// its tint, highlight and hit area; this object never handles audio or input.
@MainActor
enum StatusBarImageRenderer {
    static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular
    )
    private static let height: CGFloat = 18
    private static let deviceWidth: CGFloat = 20
    private static let gap: CGFloat = 5
    private static let dividerWidth: CGFloat = 0.5
    private static let valueWidth = ceil(("100%" as NSString).size(withAttributes: [.font: font]).width)
    static let imageWidth = ceil(deviceWidth + gap + dividerWidth + gap + valueWidth)
    static let itemLength = imageWidth + 12

    static func image(deviceIcon: AudioDeviceIcon, content: StatusBarVolumePresentation.Content,
                      hasWarning: Bool, increasedContrast: Bool) -> NSImage {
        let device = symbol(DeviceIconRendering.symbolName(for: deviceIcon))
            ?? symbol("speaker.wave.2.fill")
        let warning = hasWarning ? symbol("exclamationmark.circle.fill") : nil
        let mute = content == .muted ? symbol("speaker.slash.fill") : nil
        let deviceFrame = fitted(device, in: hasWarning
            ? NSRect(x: 0, y: 2, width: 15, height: 14)
            : NSRect(x: 2, y: 1, width: 16, height: 16))
        let slot = NSRect(x: deviceWidth + gap + dividerWidth + gap, y: 0,
                          width: valueWidth, height: height)
        let muteFrame = fitted(mute, in: NSRect(x: slot.midX - 8, y: 1, width: 16, height: 16))
        let text: String
        switch content {
        case let .percentage(value): text = "\(value)%"
        case .muted: text = ""
        case .unavailable: text = "—"
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let textOrigin = NSPoint(x: slot.midX - textSize.width / 2, y: (height - textSize.height) / 2)
        let image = NSImage(size: NSSize(width: imageWidth, height: height), flipped: false) { _ in
            device?.draw(in: deviceFrame)
            warning?.draw(in: NSRect(x: 12, y: 0, width: 8, height: 8))
            NSColor.black.withAlphaComponent(increasedContrast ? 0.8 : 0.35).setFill()
            NSRect(x: deviceWidth + gap, y: 3.5, width: dividerWidth, height: 11).fill()
            if let mute {
                mute.draw(in: muteFrame)
            } else {
                (text as NSString).draw(at: textOrigin, withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
    }

    private static func fitted(_ image: NSImage?, in rect: NSRect) -> NSRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}
