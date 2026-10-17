import AppKit
import SwiftUI
import XCTest
@testable import ToneHop

@MainActor
final class GlassPanelHostTests: XCTestCase {
    func testFirstShowAcquiresKeyboardFocusBeforeRevealingGlass() async throws {
        let fixture = try makeSizingFixture()
        defer { fixture.stop() }
        NSApp.deactivate()
        XCTAssertFalse(NSApp.isActive)
        fixture.host.show(from: fixture.button)
        // AppKit may reactivate a hosted test process after deactivate(). The
        // required behavior is real key acquisition before visible glass,
        // irrespective of the application's final activation state.
        XCTAssertTrue(fixture.host.window.isKeyWindow,
                      "The real panel must acquire key status without waiting for an interior click")
        XCTAssertEqual(fixture.host.window.alphaValue, 0)
        await open(fixture)
        XCTAssertTrue(fixture.host.window.isKeyWindow)
        XCTAssertGreaterThanOrEqual(fixture.host.window.alphaValue, 0.99)
        XCTAssertFalse(fixture.host.window.ignoresMouseEvents)
    }

    func testVisibleHostGrowsAndShrinksWithRefreshedDevices() async throws {
        let fixture = try makeSizingFixture()
        defer { fixture.stop() }
        await open(fixture)
        let emptyHeight = fixture.content.preferredContentSize.height

        fixture.hardware.deviceCount = 4
        fixture.store.refresh()
        await waitUntil { fixture.store.devices.count == 4 && fixture.content.preferredContentSize.height > emptyHeight }
        await waitUntil { self.hostFitsContent(fixture) }
        assertHostFitsContent(fixture)
        let expandedHeight = fixture.content.preferredContentSize.height

        fixture.hardware.deviceCount = 1
        fixture.store.refresh()
        await waitUntil { fixture.store.devices.count == 1 && fixture.content.preferredContentSize.height < expandedHeight }
        await waitUntil { self.hostFitsContent(fixture) }
        assertHostFitsContent(fixture)
        XCTAssertTrue(fixture.host.isShown)
    }

    func testRefreshDuringOpeningReanchorsPanelAndCompletesOnce() async throws {
        let fixture = try makeSizingFixture()
        defer { fixture.stop() }
        let emptyHeight = fixture.content.preferredContentSize.height
        fixture.host.show(from: fixture.button)
        let opened = expectation(description: "resized opening completes")
        var completions = 0
        fixture.host.animate(visible: true, reduceMotion: false) {
            completions += 1
            opened.fulfill()
        }
        try await Task.sleep(for: .milliseconds(40))
        fixture.hardware.deviceCount = 4
        fixture.store.refresh()
        await waitUntil { fixture.store.devices.count == 4 && fixture.content.preferredContentSize.height > emptyHeight }
        await fulfillment(of: [opened], timeout: 2)
        assertHostFitsContent(fixture)
        try await Task.sleep(for: .milliseconds(350))
        assertHostFitsContent(fixture)
        XCTAssertEqual(completions, 1, "The replaced transition must not deliver its retired completion")
    }

    func testSizeChangesDuringClosingAndWhileHiddenDoNotReopenHost() async throws {
        let fixture = try makeSizingFixture()
        defer { fixture.stop() }
        await open(fixture)
        let emptyHeight = fixture.content.view.frame.height
        let closed = expectation(description: "resized closing completes")
        var completions = 0
        fixture.host.animate(visible: false, reduceMotion: false) {
            completions += 1
            fixture.host.close()
            closed.fulfill()
        }
        try await Task.sleep(for: .milliseconds(40))
        fixture.hardware.deviceCount = 4
        fixture.store.refresh()
        await waitUntil {
            fixture.store.devices.count == 4 && fixture.content.view.frame.height > emptyHeight
        }
        XCTAssertEqual(completions, 0, "The new size must be applied while closing is still in flight")
        XCTAssertTrue(fixture.host.isShown)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertFalse(fixture.host.isShown)

        fixture.hardware.deviceCount = 1
        fixture.store.refresh()
        await waitUntil { fixture.store.devices.count == 1 }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(fixture.host.isShown, "A late layout notification must not order the panel back in")
        XCTAssertEqual(completions, 1)
        await open(fixture)
        assertHostFitsContent(fixture)
    }

    func testResizeAndReverseClosingKeepLatestOpeningIntent() async throws {
        let fixture = try makeSizingFixture()
        defer { fixture.stop() }
        await open(fixture)
        var retiredCloseCompleted = false
        fixture.host.animate(visible: false, reduceMotion: false) {
            retiredCloseCompleted = true
            fixture.host.close()
        }
        try await Task.sleep(for: .milliseconds(40))
        fixture.hardware.deviceCount = 4
        fixture.store.refresh()
        await waitUntil { fixture.store.devices.count == 4 }
        await open(fixture)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(retiredCloseCompleted)
        XCTAssertTrue(fixture.host.isShown)
        XCTAssertFalse(fixture.host.window.ignoresMouseEvents)
        assertHostFitsContent(fixture)
    }

    func testReducedMotionCompletionWaitsForOpacityAndKeepsNaturalContent() async throws {
        let fixture = R08PreviewFixture.make(quitMenu: StatusBarController.makeQuitMenu())
        let content = NSHostingController(rootView: OutputDevicesView(store: fixture.store))
        let host = GlassPanelHost(content: content)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { host.close(); NSStatusBar.system.removeStatusItem(item); fixture.store.stop() }
        host.show(from: try XCTUnwrap(item.button))
        let naturalSize = content.view.frame.size
        let opened = expectation(description: "reduced opening fades in")
        host.animate(visible: true, reduceMotion: true) { opened.fulfill() }
        await fulfillment(of: [opened], timeout: 2)
        let restingOrigin = host.window.frame.origin
        var completed = false
        let closed = expectation(description: "reduced closing fades out")
        host.animate(visible: false, reduceMotion: true) { completed = true; closed.fulfill() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(completed, "A shell group without animation must not end the opacity transition early")
        XCTAssertEqual(content.view.frame.size, naturalSize)
        XCTAssertEqual(host.window.frame.origin, restingOrigin, "Reduced motion must not translate the panel")
        XCTAssertEqual(content.view.alphaValue, 1, "Content and material fade together through the window")
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertLessThan(host.window.alphaValue, 0.01)
        XCTAssertEqual(host.window.frame.origin, restingOrigin)
    }

    func testWholePanelTransitionsKeepNaturalSizeAndFadeBeforeRemoval() async throws {
        let fixture = R08PreviewFixture.make(quitMenu: StatusBarController.makeQuitMenu())
        fixture.interactions.start()
        await fixture.interactions.shortcuts.drain()
        fixture.store.refresh()
        for _ in 0..<200 {
            if fixture.store.devices.count == 4,
               fixture.interactions.volume.rows.values.filter({ $0.snapshot != nil }).count == 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.store.devices.count, 4)
        XCTAssertEqual(fixture.interactions.shortcuts.offlineBindings.count, 1)
        let content = NSHostingController(rootView: OutputDevicesView(store: fixture.store, interactions: fixture.interactions))
        let host = GlassPanelHost(content: content)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer {
            host.close()
            NSStatusBar.system.removeStatusItem(item)
            fixture.store.stop()
        }
        let button = try XCTUnwrap(item.button)
        host.show(from: button)
        let size = content.view.frame.size
        XCTAssertEqual(size.width, 328)
        let surfaces = try XCTUnwrap(host.window.contentView).subviews.compactMap { $0 as? NSGlassEffectView }
        let glass = try XCTUnwrap(surfaces.first)
        XCTAssertEqual(surfaces.count, 1)
        XCTAssertEqual(glass.style, .regular)
        XCTAssertEqual(glass.frame.size, size, "The opening begins at full size, never as a capsule")
        let opened = expectation(description: "glass opening completes")
        host.animate(visible: true) { opened.fulfill() }
        XCTAssertEqual(content.view.frame.size, size)
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(content.view.frame.size, size)
        XCTAssertEqual(content.view.layer?.affineTransform(), .identity)

        let display = try XCTUnwrap(fixture.store.devices.first { $0.name == "Redmi 27 NU" })
        fixture.store.select(display)
        for _ in 0..<200 {
            if fixture.store.feedbackKind == .failure, !fixture.store.isSwitching { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.store.presentationFeedback, expectedLocalized("Could not switch to Redmi 27 NU", "无法切换到 Redmi 27 NU"))
        host.window.displayIfNeeded()

        let closed = expectation(description: "glass closing completes")
        host.animate(visible: false) { closed.fulfill() }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(content.view.frame.size.width, 328)
        XCTAssertEqual(glass.frame.size, content.view.frame.size, "The glass never collapses into an empty shell")
        XCTAssertEqual(host.window.frame.size, content.view.frame.size)
        XCTAssertEqual(content.view.alphaValue, 1, "No independent early content fade may leave glass behind")
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertLessThan(host.window.alphaValue, 0.01, "Finish fading the entire panel before ordering it out")
        XCTAssertEqual(content.view.layer?.affineTransform(), .identity)
        host.close()
        XCTAssertFalse(host.isShown)
        try await fixture.store.shutdown()
    }

    func testOfflineDisclosureInterpolatesContentAndGlassAtFixedTopEdge() async throws {
        let fixture = try await makeDisclosureFixture()
        defer { fixture.stop() }
        let collapsed = fixture.host.window.frame
        let selectedDevice = fixture.store.currentDeviceID

        try pressOfflineDisclosure(fixture)
        let expanding = try await sampleDisclosure(fixture, for: .milliseconds(340))
        let expanded = try XCTUnwrap(expanding.last)
        XCTAssertGreaterThan(expanded.height, collapsed.height + 20)
        assertIntermediateHeights(expanding, between: collapsed.height, and: expanded.height)
        assertDisclosureGeometry(expanding, anchoredAt: collapsed.maxY)

        try pressOfflineDisclosure(fixture)
        let collapsing = try await sampleDisclosure(fixture, for: .milliseconds(340))
        XCTAssertEqual(try XCTUnwrap(collapsing.last).height, collapsed.height, accuracy: 1)
        assertIntermediateHeights(collapsing, between: collapsed.height, and: expanded.height)
        assertDisclosureGeometry(collapsing, anchoredAt: collapsed.maxY)
        XCTAssertEqual(fixture.store.currentDeviceID, selectedDevice,
                       "Expanding saved records must not select an output")
        XCTAssertTrue(fixture.host.isShown)
    }

    func testOfflineDisclosureCanReverseBeforeExpansionFinishes() async throws {
        let fixture = try await makeDisclosureFixture()
        defer { fixture.stop() }
        let collapsed = fixture.host.window.frame
        // Measure this fixture's full excursion through the public control;
        // the regression does not duplicate the view's row-height constants.
        try pressOfflineDisclosure(fixture)
        let fullyExpanded = try await sampleDisclosure(fixture, for: .milliseconds(340))
        let expandedHeight = try XCTUnwrap(fullyExpanded.last).height
        try pressOfflineDisclosure(fixture)
        _ = try await sampleDisclosure(fixture, for: .milliseconds(340))
        XCTAssertEqual(fixture.host.window.frame.height, collapsed.height, accuracy: 1)

        try pressOfflineDisclosure(fixture)
        await waitUntil { fixture.host.window.frame.height > collapsed.height + 10 }
        let heightBeforePress = fixture.host.window.frame.height
        XCTAssertLessThan(heightBeforePress, expandedHeight - 1)
        let expandedValue = disclosureValue(fixture)

        try pressOfflineDisclosure(fixture)
        let samples = try await sampleDisclosure(fixture, for: .milliseconds(340))
        let reversalIndex = try XCTUnwrap(samples.firstIndex { $0.accessibilityValue != expandedValue },
                                         "The public control must acknowledge the collapse action")
        let reversing = Array(samples[reversalIndex...])
        let reversalHeight = try XCTUnwrap(reversing.first).height
        assertDisclosureGeometry(samples, anchoredAt: collapsed.maxY)
        assertIntermediateHeights(reversing, between: collapsed.height, and: reversalHeight)
        XCTAssertEqual(try XCTUnwrap(samples.last).height, collapsed.height, accuracy: 1)
        let heights = [heightBeforePress] + samples.map(\.height)
        let largestStep = zip(heights, heights.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        print("Disclosure reversal: maxHeight=\(heights.max() ?? 0), fullHeight=\(expandedHeight), maxStep=\(largestStep)")
        // SwiftUI may retain velocity briefly while retargeting. Require a
        // continuous turn before full expansion, not an immediate velocity flip.
        XCTAssertLessThan(heights.max() ?? 0, expandedHeight - 1)
        XCTAssertLessThan(largestStep, (expandedHeight - collapsed.height) / 2,
                          "A reversal must not jump between the collapsed and expanded sizes")
        XCTAssertTrue(fixture.host.isShown)
        XCTAssertFalse(fixture.host.window.ignoresMouseEvents)
    }

    func testClosingDuringOfflineExpansionKeepsOriginalDeadlineAndStaysClosed() async throws {
        let fixture = try await makeDisclosureFixture()
        defer { fixture.stop() }
        let collapsedHeight = fixture.host.window.frame.height
        try pressOfflineDisclosure(fixture)
        await waitUntil { fixture.host.window.frame.height > collapsedHeight + 3 }
        let closingStart = ContinuousClock.now
        var closedAfter: Duration?
        var completions = 0
        let closed = expectation(description: "closing completes during disclosure layout")
        fixture.host.animate(visible: false, reduceMotion: false) {
            completions += 1
            closedAfter = closingStart.duration(to: .now)
            fixture.host.close()
            closed.fulfill()
        }
        await fulfillment(of: [closed], timeout: 2)
        // Closing is 160 ms. Allow scheduling slack, but reject restarting that
        // duration on every frame of the 220 ms disclosure animation.
        print("Disclosure closing elapsed: \(try XCTUnwrap(closedAfter))")
        XCTAssertLessThan(try XCTUnwrap(closedAfter), .milliseconds(260))
        XCTAssertFalse(fixture.host.isShown)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(fixture.host.isShown, "Late disclosure geometry must not order the panel back in")
    }

    private func makeDisclosureFixture() async throws -> GlassDisclosureFixture {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "Intermediate-motion assertions require the system's standard motion setting")
        let preview = R08PreviewFixture.make(quitMenu: StatusBarController.makeQuitMenu())
        preview.interactions.start()
        await preview.interactions.shortcuts.drain()
        preview.store.refresh()
        await waitUntil {
            preview.store.devices.count == 4
                && preview.interactions.shortcuts.offlineBindings.count == 1
                && preview.interactions.volume.rows.values.filter { $0.snapshot != nil }.count == 4
        }
        let content = NSHostingController(rootView: OutputDevicesView(store: preview.store,
                                                                      interactions: preview.interactions))
        let host = GlassPanelHost(content: content)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let button = try XCTUnwrap(item.button)
        button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        await waitUntil {
            guard let window = button.window, let screen = window.screen else { return false }
            return window.isVisible && !button.visibleRect.isEmpty && window.frame.minY >= screen.visibleFrame.maxY
        }
        var anchorRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        var stableReadings = 0
        await waitUntil {
            let next = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            stableReadings = next == anchorRect ? stableReadings + 1 : 0
            anchorRect = next
            return stableReadings >= 4
        }
        host.show(from: button)
        let opened = expectation(description: "disclosure fixture opens")
        host.animate(visible: true, reduceMotion: false) { opened.fulfill() }
        await fulfillment(of: [opened], timeout: 2)
        host.window.displayIfNeeded()
        // A public query for our own test process materializes SwiftUI's lazy
        // accessibility tree. The action below still runs in-process; no TCC
        // setting or other application's UI is touched.
        let pid = ProcessInfo.processInfo.processIdentifier
        let accessibilityStatus = await Task.detached {
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                                  kAXWindowsAttribute as CFString, &windows).rawValue
        }.value
        XCTAssertEqual(accessibilityStatus, AXError.success.rawValue)
        print("Disclosure initial top: \(host.window.frame.maxY), anchor top: \((anchorRect?.minY ?? 0) - 8)")
        return GlassDisclosureFixture(store: preview.store, content: content, host: host, item: item,
                                      disclosure: try offlineDisclosure(in: content.view))
    }

    private func pressOfflineDisclosure(_ fixture: GlassDisclosureFixture,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(fixture.disclosure.accessibilityPerformPress?(), true, file: file, line: line)
    }

    private func disclosureValue(_ fixture: GlassDisclosureFixture) -> String {
        let getter = fixture.disclosure.accessibilityValue as (() -> Any?)?
        return String(describing: getter?() as Any)
    }

    private func offlineDisclosure(in content: NSView,
                                   file: StaticString = #filePath, line: UInt = #line) throws -> AnyObject {
        // Use the same public accessibility action as keyboard/assistive input.
        // No SwiftUI state reflection, KVC, or private view implementation names.
        var pending: [Any] = [content]
        var visited = Set<ObjectIdentifier>()
        var descriptions: [String] = []
        while let next = pending.popLast() {
            // SwiftUI's public AX objects need not formally declare the full
            // AppKit protocol; query the public selectors they implement.
            let element = next as AnyObject
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let label = [element.accessibilityLabel?(), element.accessibilityTitle?(),
                         element.accessibilityHelp?()]
                .compactMap { $0 }.joined(separator: " ")
            let role = element.accessibilityRole?()
            descriptions.append("\(role?.rawValue ?? "nil"): \(label)")
            if role == .disclosureTriangle, label.contains(expectedLocalized("Devices Not Found", "未发现的设备")) {
                return element
            }
            pending.append(contentsOf: element.accessibilityChildren?() ?? [])
        }
        XCTFail("Missing offline disclosure in public accessibility tree: \(descriptions)", file: file, line: line)
        throw CocoaError(.coderValueNotFound)
    }

    private func sampleDisclosure(_ fixture: GlassDisclosureFixture,
                                  for duration: Duration) async throws -> [DisclosureGeometrySample] {
        let deadline = ContinuousClock.now.advanced(by: duration)
        var samples: [DisclosureGeometrySample] = []
        repeat {
            try await Task.sleep(for: .milliseconds(8))
            let glass = try XCTUnwrap(fixture.host.window.contentView?.subviews.first { $0 is NSGlassEffectView })
            samples.append(DisclosureGeometrySample(window: fixture.host.window.frame,
                content: fixture.content.view.frame, glass: glass.frame,
                canvas: try XCTUnwrap(fixture.host.window.contentView).bounds,
                transform: fixture.content.view.layer?.affineTransform(),
                accessibilityValue: disclosureValue(fixture)))
        } while ContinuousClock.now < deadline
        return samples
    }

    private func assertIntermediateHeights(_ samples: [DisclosureGeometrySample],
                                            between lower: CGFloat, and upper: CGFloat,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let intermediate = Set(samples.map(\.height).filter { $0 > lower + 0.5 && $0 < upper - 0.5 }
            .map { Int(($0 * 10).rounded()) })
        print("Disclosure geometry: range=\(samples.map(\.height).min() ?? 0)...\(samples.map(\.height).max() ?? 0), intermediateHeights=\(intermediate.count), samples=\(samples.count)")
        XCTAssertGreaterThanOrEqual(intermediate.count, 3,
                                   "The actual panel must pass through multiple intermediate heights", file: file, line: line)
    }

    private func assertDisclosureGeometry(_ samples: [DisclosureGeometrySample], anchoredAt top: CGFloat,
                                          file: StaticString = #filePath, line: UInt = #line) {
        for sample in samples {
            XCTAssertEqual(sample.window.maxY, top, accuracy: 1, file: file, line: line)
            XCTAssertEqual(sample.window.width, 328, file: file, line: line)
            // AppKit rounds window and backing-layer bounds to display pixels,
            // while SwiftUI reports fractional intermediate point sizes.
            for bounds in [sample.glass, sample.canvas] {
                XCTAssertEqual(bounds.minY, sample.content.minY, accuracy: 1, file: file, line: line)
                XCTAssertEqual(bounds.width, sample.content.width, accuracy: 1, file: file, line: line)
                XCTAssertEqual(bounds.height, sample.content.height, accuracy: 1, file: file, line: line)
            }
            XCTAssertEqual(sample.window.height, sample.content.height, accuracy: 1, file: file, line: line)
            XCTAssertEqual(sample.transform, .identity, file: file, line: line)
        }
    }

    private func makeSizingFixture() throws -> GlassSizingFixture {
        let hardware = GlassSizingHardware()
        let store = AudioStore(hardware: hardware, routes: GlassSizingRoutes())
        let content = NSHostingController(rootView: OutputDevicesView(store: store))
        let host = GlassPanelHost(content: content)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        return GlassSizingFixture(hardware: hardware, store: store, content: content,
                                  host: host, item: item, button: try XCTUnwrap(item.button))
    }

    private func open(_ fixture: GlassSizingFixture) async {
        fixture.host.show(from: fixture.button)
        let opened = expectation(description: "opening completes")
        fixture.host.animate(visible: true, reduceMotion: false) { opened.fulfill() }
        await fulfillment(of: [opened], timeout: 2)
    }

    private func hostFitsContent(_ fixture: GlassSizingFixture) -> Bool {
        let preferred = fixture.content.preferredContentSize
        let shell = fixture.host.window.contentView?.subviews.first { $0 is NSGlassEffectView }
        return fixture.content.view.frame.size == preferred
            && fixture.host.window.contentView?.bounds.size == preferred
            && shell?.frame == NSRect(origin: .zero, size: preferred)
    }

    private func assertHostFitsContent(_ fixture: GlassSizingFixture,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let preferred = fixture.content.preferredContentSize
        XCTAssertEqual(fixture.host.window.contentView?.bounds.size, preferred, file: file, line: line)
        XCTAssertEqual(fixture.content.view.frame.size, preferred, file: file, line: line)
        XCTAssertTrue(hostFitsContent(fixture), "The visible shell must fit the current natural content", file: file, line: line)
        XCTAssertEqual(fixture.content.view.layer?.affineTransform(), .identity, file: file, line: line)
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
}

private struct DisclosureGeometrySample {
    let window: NSRect
    let content: NSRect
    let glass: NSRect
    let canvas: NSRect
    let transform: CGAffineTransform?
    let accessibilityValue: String
    var height: CGFloat { window.height }
}

@MainActor
private struct GlassDisclosureFixture {
    let store: AudioStore
    let content: NSHostingController<OutputDevicesView>
    let host: GlassPanelHost
    let item: NSStatusItem
    let disclosure: AnyObject

    func stop() {
        host.close()
        NSStatusBar.system.removeStatusItem(item)
        store.stop()
    }
}

@MainActor
private struct GlassSizingFixture {
    let hardware: GlassSizingHardware
    let store: AudioStore
    let content: NSHostingController<OutputDevicesView>
    let host: GlassPanelHost
    let item: NSStatusItem
    let button: NSStatusBarButton

    func stop() {
        host.close()
        NSStatusBar.system.removeStatusItem(item)
        store.stop()
    }
}

@MainActor
private final class GlassSizingHardware: AudioHardwareProviding {
    var deviceCount = 0
    nonisolated func beginShutdown() {}
    func snapshot() async throws -> CoreAudioSnapshot {
        let devices = (0..<deviceCount).map { index in
            AudioDevice(id: "hal:glass-sizing-\(index)", name: "Fixture speaker \(index)", transport: .speaker,
                        backend: .coreAudio(uid: "glass-sizing-\(index)"))
        }
        return CoreAudioSnapshot(devices: devices, currentDeviceID: devices.first?.id,
                                 systemSoundDeviceID: devices.first?.id, warnings: [],
                                 discovery: AudioDiscoverySourceInventory(observedIdentifiers:
                                    Set((0..<deviceCount).map { "glass-sizing-\($0)" }), isComplete: true),
                                 isOutputInventoryComplete: true)
    }
    func select(uid: String) async throws { XCTFail("Layout must not select audio") }
    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws {}
    func stopObserving() async {}
}

@MainActor
private final class GlassSizingRoutes: PrivateRouting {
    var onChange: (() -> Void)?
    func start() {}
    func stop() {}
    func beginShutdown() {}
    func snapshot() -> PrivateRouteSnapshot { .init(routes: [], warning: nil, diagnostics: "glass sizing test") }
    func select(identifier: String) async throws { XCTFail("Layout must not select a route") }
    func prepareToLeave() async throws { XCTFail("Layout must not prepare an audio change") }
    func completedLeave() async throws { XCTFail("Layout must not clean up streams") }
}
