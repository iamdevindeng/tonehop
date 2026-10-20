import AppKit
import XCTest
@testable import ToneHop

/// Captures the actual AppKit status button, including its template tint.
/// This does not start audio services or register shortcuts.
@MainActor
final class StatusBarRenderingTests: XCTestCase {
    func testNativeButtonKeepsItsWidthAcrossStatesAndAppearances() async throws {
        let item = NSStatusBar.system.statusItem(withLength: StatusBarImageRenderer.itemLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        button.imagePosition = .imageOnly
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while button.window?.isVisible != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(button.window?.isVisible == true)
        let buttonSize = button.bounds.size
        let states: [(String, StatusBarVolumePresentation.Content, Bool)] = [
            ("9", .percentage(9), false),
            ("65", .percentage(65), false),
            ("100", .percentage(100), false),
            ("muted", .muted, false),
            ("unavailable", .unavailable, false),
            ("zero", .percentage(0), false),
            ("warning-muted", .muted, true)
        ]
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua),
                                              ("dark", NSAppearance.Name.darkAqua)] {
            button.appearance = NSAppearance(named: appearance)
            for (name, state, warning) in states {
                let image = StatusBarImageRenderer.image(deviceIcon: .systemSymbol("homepodmini.fill"),
                    content: state, hasWarning: warning, increasedContrast: false)
                button.image = image
                button.displayIfNeeded()
                XCTAssertTrue(image.isTemplate, "The native button must control foreground and highlight tint.")
                XCTAssertEqual(button.bounds.size, buttonSize, "State changes must not move neighboring menu items.")
                XCTAssertLessThan(image.size.width, button.bounds.width)
                XCTAssertLessThanOrEqual(image.size.height, button.bounds.height)
                let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
                button.cacheDisplay(in: button.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let language = Bundle.main.preferredLocalizations.first ?? "unknown"
                let filename = "tonehop-status-\(language)-\(appearanceName)-\(name)"
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = filename
                attachment.lifetime = .keepAlways
                add(attachment)
                try png.write(to: URL(fileURLWithPath: "/private/tmp/\(filename).png"), options: .atomic)
            }
        }
        XCTAssertNotNil(NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil),
                        "The approved mute symbol must be available on the supported system.")
    }
}
