import AppKit
import SwiftUI
import XCTest
@testable import ToneHop

/// Offscreen rendering uses the existing in-memory fixture. It never opens a
/// panel, registers real shortcuts, or touches system audio output.
@MainActor
final class LocalizationRenderingTests: XCTestCase {
    func testPreparationSummaryFitsItsSingleLineAtProductionWidth() {
        let summary = DeviceRowView.unavailableHintText(for: RetainedRouteCapability.preparationHint)
        let measured = (summary as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
        let textWidth: CGFloat = 328 - 2 * 16 - 2 * 10 - 48
        XCTAssertLessThanOrEqual(measured.width, textWidth,
                                 "Preparation guidance must fit the reserved single line in both languages.")
        XCTAssertLessThanOrEqual(measured.height, DeviceRowView.issueHeight)
    }

    func testConfirmingRowsExposeSavedShortcutsToAccessibility() async throws {
        let fixture = R08PreviewFixture.make(quitMenu: StatusBarController.makeQuitMenu())
        defer { fixture.store.stop() }
        fixture.interactions.start()
        await fixture.interactions.shortcuts.drain()
        // Before the first discovery snapshot, saved identities remain in the
        // main list as confirming rows. Do not refresh the fixture's catalog.
        let bindings = fixture.interactions.shortcuts.confirmingBindings
        XCTAssertEqual(bindings.count, 5)
        XCTAssertTrue(fixture.store.devices.isEmpty)
        XCTAssertTrue(fixture.interactions.shortcuts.offlineBindings.isEmpty)

        let content = NSHostingView(rootView: OutputDevicesView(store: fixture.store,
                                                                 interactions: fixture.interactions))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 328, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        content.layoutSubtreeIfNeeded()

        // Materialize SwiftUI's lazy accessibility tree through our own test
        // process, without opening a window or accessing another application's UI.
        let pid = ProcessInfo.processInfo.processIdentifier
        let accessibilityStatus = await Task.detached {
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                                  kAXWindowsAttribute as CFString, &windows).rawValue
        }.value
        XCTAssertEqual(accessibilityStatus, AXError.success.rawValue)

        var pending: [Any] = [content]
        var visited = Set<ObjectIdentifier>()
        var rows: [(label: String, value: String)] = []
        while let next = pending.popLast() {
            // Some SwiftUI AX objects implement the public selectors without
            // declaring the complete NSAccessibility protocol.
            let element = next as AnyObject
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let label = [element.accessibilityLabel?(), element.accessibilityTitle?()]
                .compactMap { $0 }.joined(separator: " ")
            let getter = element.accessibilityValue as (() -> Any?)?
            rows.append((label, getter?() as? String ?? ""))
            pending.append(contentsOf: element.accessibilityChildren?() ?? [])
        }

        for binding in bindings {
            let shortcut = ShortcutKeyDisplay.label(binding.shortcut)
            XCTAssertTrue(rows.contains {
                let spokenText = "\($0.label) \($0.value)"
                return spokenText.contains(binding.lastKnownName) && spokenText.contains(shortcut)
            },
                          "The confirming row for \(binding.lastKnownName) must expose its saved shortcut \(shortcut). Public AX tree: \(rows)")
        }
    }

    func testLocalizedPanelAndDialogRenderWithOriginalDeviceNames() async throws {
        let fixture = R08PreviewFixture.make(quitMenu: StatusBarController.makeQuitMenu())
        defer { fixture.store.stop() }
        fixture.interactions.start()
        await fixture.interactions.shortcuts.drain()
        fixture.store.refresh()
        for _ in 0..<200 {
            if fixture.store.devices.count == 4,
               fixture.interactions.shortcuts.offlineBindings.count == 1,
               fixture.interactions.volume.rows.values.filter({ $0.snapshot != nil }).count == 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Set(fixture.store.devices.map(\.name)),
                       ["Mac mini Speakers", "Redmi 27 NU", "OrayVirtualAudioDevice", "Bedroom"])
        XCTAssertEqual(fixture.interactions.shortcuts.offlineBindings.first?.lastKnownName, "EDIFIER W820NB")

        let footer = fixture.store.presentationFeedback
        let footerSize = (footer as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        XCTAssertLessThanOrEqual(footerSize.width, 276,
                                 "The neutral footer must not strand a modifier symbol on a second line.")


        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
            let root = OutputDevicesView(store: fixture.store, interactions: fixture.interactions)
                .environment(\.colorScheme, scheme)
                .background(Color(nsColor: .windowBackgroundColor))
            let content = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 328, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = content
            content.layoutSubtreeIfNeeded()
            let size = content.fittingSize
            XCTAssertEqual(size.width, 328, accuracy: 0.5)
            XCTAssertGreaterThan(size.height, 250)
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded()
            try await attach(content, scene: "output-\(name)")
            var descendants: [NSView] = [content]
            var recorderCount = 0
            while let view = descendants.popLast() {
                if let recorder = view as? ShortcutRecordingButton {
                    recorderCount += 1
                    XCTAssertGreaterThanOrEqual(recorder.bounds.intersection(recorder.visibleRect).width,
                                                recorder.bounds.width - 0.5,
                                                "The full shortcut control must fit the scroll viewport: bounds=\(recorder.bounds), visible=\(recorder.visibleRect)")
                }
                descendants.append(contentsOf: view.subviews)
            }
            XCTAssertEqual(recorderCount, fixture.store.devices.count)
            window.close()

            let dialog = RecordRemovalAlerts.confirmation(name: "Bedroom 卧室 %@ 🎧")
            dialog.window.appearance = NSAppearance(named: appearance)
            let dialogContent = try XCTUnwrap(dialog.window.contentView)
            dialogContent.layoutSubtreeIfNeeded()
            XCTAssertTrue(dialog.titleLabel.stringValue.contains("Bedroom 卧室 %@ 🎧"))
            try await attach(dialogContent, scene: "remove-\(name)")
            dialog.window.close()
        }
    }

    private func attach(_ view: NSView, scene: String) async throws {
        // The first offscreen draw can materialize the lazy scroll content.
        // Let its deferred layout finish before capturing the final bitmap.
        let warmup = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: warmup)
        try await Task.sleep(for: .milliseconds(20))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        let language = Bundle.main.preferredLocalizations.first ?? "unknown"
        let name = "tonehop-localization-\(language)-\(scene)"
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: "/private/tmp/\(name).png")
        try png.write(to: url, options: .atomic)
        print("Localization render: \(url.path)")
    }
}
