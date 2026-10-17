import AppKit
import XCTest
@testable import ToneHop

/// Exercises the configured status button's public action and native windows.
/// Both audio dependencies are inert fixtures, including refresh on opening.
/// Activation and window presentation use the production AppKit path. Visibility
/// must not depend on hosted clicks receiving foreground activation or key status.
/// Real focus/material belongs to the separate GUI checks.
/// performClick clears its own highlight after the action, so physical mouse
/// highlight behavior belongs to the separate native GUI regression.
@MainActor
final class StatusBarPopoverTests: XCTestCase {
    func testProductionOpeningRemainsVisibleBeyondActivationDeadlineAndCanReopen() async throws {
        let hardware = PopoverTestHardware()
        let routes = PopoverTestRoutes()
        let store = AudioStore(hardware: hardware, routes: routes)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let controller = StatusBarController(store: store, statusItem: item)
        defer { controller.stop(); store.stop() }
        let button = try XCTUnwrap(item.button)
        await waitUntil("status anchor ready") { button.window?.isVisible == true }
        let existing = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        button.performClick(nil)
        await waitUntil("production button action reveals an interactive panel") {
            self.newPopoverWindow(excluding: existing, anchor: button.window) != nil
        }
        let panel = try XCTUnwrap(newPopoverWindow(excluding: existing, anchor: button.window))
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertTrue(panel.isVisible, "Opening must not expire while waiting for application activation")
        XCTAssertGreaterThanOrEqual(panel.alphaValue, 0.99)
        XCTAssertFalse(panel.ignoresMouseEvents)

        button.performClick(nil)
        await waitUntil("shown panel closes") { !panel.isVisible }
        button.performClick(nil)
        await waitUntil("a fresh production click reopens the same panel") {
            panel.isVisible && panel.alphaValue >= 0.99 && !panel.ignoresMouseEvents
        }
        XCTAssertTrue(hardware.selectedUIDs.isEmpty)
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
    }

    func testLateActivationAndKeyNotificationsCannotReopenClosedOrStoppedPanel() async throws {
        let hardware = PopoverTestHardware()
        let routes = PopoverTestRoutes()
        let store = AudioStore(hardware: hardware, routes: routes)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let controller = StatusBarController(store: store, statusItem: item)
        defer { controller.stop(); store.stop() }
        let button = try XCTUnwrap(item.button)
        await waitUntil("status anchor ready") { button.window?.isVisible == true }
        let existing = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        button.performClick(nil)
        await waitUntil("production panel opens before closing") {
            self.newPopoverWindow(excluding: existing, anchor: button.window) != nil
        }
        let panel = try XCTUnwrap(newPopoverWindow(excluding: existing, anchor: button.window))
        button.performClick(nil)
        await waitUntil("second click closes the panel") { !panel.isVisible }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(panel.isVisible, "Late activation and key notifications must not undo closing")

        button.performClick(nil)
        await waitUntil("a fresh click reopens before stopping") {
            panel.isVisible && panel.alphaValue >= 0.99 && !panel.ignoresMouseEvents
        }
        controller.stop()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(panel.isVisible, "Late activation and key notifications must not undo stop")
        XCTAssertTrue(hardware.selectedUIDs.isEmpty)
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
    }

    func testRealKeyLossClosesNonactivatingPanelAndLateFocusCannotReopenIt() async throws {
        let hardware = PopoverTestHardware()
        let routes = PopoverTestRoutes()
        let store = AudioStore(hardware: hardware, routes: routes)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let controller = StatusBarController(store: store, statusItem: item)
        defer { controller.stop(); store.stop() }
        let button = try XCTUnwrap(item.button)
        await waitUntil("status anchor ready") { button.window?.isVisible == true }
        let existing = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        button.performClick(nil)
        await waitUntil("production panel opens before losing key") {
            self.newPopoverWindow(excluding: existing, anchor: button.window) != nil
        }
        let panel = try XCTUnwrap(newPopoverWindow(excluding: existing, anchor: button.window))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.isKeyWindow)

        // Exercise the real public NSWindow transition and its notification;
        // application activation need not change for this panel to lose key.
        panel.resignKey()
        await waitUntil("loss of the actual panel key closes its presentation") { !panel.isVisible }

        panel.makeKey()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(panel.isVisible, "Late focus must not reverse an already accepted dismissal.")
        XCTAssertTrue(hardware.selectedUIDs.isEmpty)
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
    }

    func testRecordRemovalModalKeepsNonactivatingHostVisibleAndReturnsItsKeyFocus() async throws {
        // The preview fixture injects audio, volume, preferences and hotkeys;
        // exercising the production coordinator cannot change real settings.
        let quitMenu = StatusBarController.makeQuitMenu()
        let fixture = R08PreviewFixture.make(quitMenu: quitMenu)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let controller = StatusBarController(store: fixture.store, interactions: fixture.interactions,
                                             quitMenu: quitMenu, statusItem: item)
        defer { controller.stop(); fixture.store.stop() }
        fixture.interactions.start()
        await fixture.interactions.shortcuts.drain()
        fixture.store.refresh()
        await waitUntil("in-memory discovery confirms a removable offline binding") {
            fixture.interactions.shortcuts.offlineBindings.count == 1 && fixture.interactions.shortcuts.canEdit
        }
        let binding = try XCTUnwrap(fixture.interactions.shortcuts.offlineBindings.first)
        let originalBindings = fixture.interactions.shortcuts.bindings
        let originalOutput = fixture.store.currentDeviceID
        let button = try XCTUnwrap(item.button)
        await waitUntil("status anchor ready") { button.window?.isVisible == true }
        let existing = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        button.performClick(nil)
        await waitUntil("production panel opens before record removal") {
            self.newPopoverWindow(excluding: existing, anchor: button.window) != nil
        }
        let panel = try XCTUnwrap(newPopoverWindow(excluding: existing, anchor: button.window))
        XCTAssertTrue(panel.isKeyWindow)

        var hostResignedKey = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { _ in MainActor.assumeIsolated { hostResignedKey = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        var modalStarted: ContinuousClock.Instant?
        var checkedModalHost = false
        let modalDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        let timer = Timer(timeInterval: 0.01, repeats: true) { timer in
            let finished = MainActor.assumeIsolated {
                guard ContinuousClock.now < modalDeadline else {
                    XCTFail("The production confirmation did not complete its native focus handoff.")
                    fixture.interactions.cancelRecordRemoval?()
                    return true
                }
                guard let modal = NSApp.modalWindow, modal.parent === panel else { return false }
                if modalStarted == nil { modalStarted = ContinuousClock.now }
                // Hold the native modal longer than the host's close animation:
                // a mistaken resign-key dismissal cannot hide behind timing.
                guard let modalStarted,
                      ContinuousClock.now >= modalStarted.advanced(by: .milliseconds(300)) else { return false }
                checkedModalHost = true
                XCTAssertTrue(hostResignedKey, "The native alert must exercise the real focus handoff.")
                XCTAssertTrue(modal.isVisible)
                // Hosted AppKit can deny activation even to a standalone NSAlert
                // (see glass-focus-r01/native-modal-baseline). Check native key
                // handoff when active; host visibility and restored panel key
                // below remain unconditional in either environment.
                if NSApp.isActive { XCTAssertTrue(modal.isKeyWindow) }
                XCTAssertTrue(panel.isVisible, "The host must remain visible during its own modal confirmation.")
                XCTAssertGreaterThanOrEqual(panel.alphaValue, 0.99)
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
                return true
            }
            if finished { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }

        fixture.interactions.removeRecord(binding)
        await waitUntil("native cancellation completes through the coordinator") {
            checkedModalHost && NSApp.modalWindow == nil && fixture.interactions.shortcuts.canEdit
        }

        XCTAssertTrue(checkedModalHost)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.isKeyWindow, "Closing the confirmation must return keyboard focus to its host.")
        XCTAssertGreaterThanOrEqual(panel.alphaValue, 0.99)
        XCTAssertEqual(fixture.interactions.shortcuts.bindings, originalBindings)
        XCTAssertEqual(fixture.store.currentDeviceID, originalOutput)
    }

    func testRapidOpenCloseOpenReversesToLastIntentAndStopPreventsLateReopen() async throws {
        let hardware = PopoverTestHardware()
        let routes = PopoverTestRoutes()
        let store = AudioStore(hardware: hardware, routes: routes)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let controller = StatusBarController(store: store, statusItem: item)
        defer { controller.stop(); store.stop() }
        let button = try XCTUnwrap(item.button)
        await waitUntil("status anchor ready") { button.window?.isVisible == true }
        let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        button.performClick(nil)
        button.performClick(nil)
        button.performClick(nil)
        await waitUntil("last open intent is shown") {
            self.newPopoverWindow(excluding: visible, anchor: button.window) != nil
        }
        let panel = try XCTUnwrap(newPopoverWindow(excluding: visible, anchor: button.window))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.ignoresMouseEvents)
        button.performClick(nil)
        button.performClick(nil)
        controller.stop()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(panel.isVisible, "Retired animation completion must not reopen its host")
        XCTAssertTrue(hardware.selectedUIDs.isEmpty)
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
    }

    func testMenuBarTracksConfirmedExternalOutputAndFallsBackWhenUnknown() async throws {
        let hardware = PopoverTestHardware()
        let store = AudioStore(hardware: hardware, routes: PopoverTestRoutes())
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let controller = StatusBarController(store: store, statusItem: item)
        defer { controller.stop(); store.stop() }
        let button = try XCTUnwrap(item.button)
        XCTAssertEqual(button.toolTip, expectedLocalized("Current output is not yet confirmed", "当前声音输出待确认"))
        store.refresh()
        await waitUntil("confirmed output reaches menu tooltip") { button.toolTip == "Test speaker" }
        hardware.current = false
        store.refresh()
        await waitUntil("unconfirmed output restores fallback tooltip") { button.toolTip == expectedLocalized("Current output is not yet confirmed", "当前声音输出待确认") }
        XCTAssertTrue(hardware.selectedUIDs.isEmpty)
    }

    func testRepeatedFailureAlertsAgainButOpeningAndRefreshDoNotReplayOldCause() async throws {
        let hardware = PopoverTestHardware()
        let store = AudioStore(hardware: hardware, routes: PopoverTestRoutes())
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let controller = StatusBarController(store: store, statusItem: item)
        defer { controller.stop(); store.stop() }
        let button = try XCTUnwrap(item.button)
        store.refresh()
        await waitUntil("current output ready") { button.toolTip == "Test speaker" }
        let absent = AudioTargetIdentity.hal(uid: "missing-menu-test")
        store.select(target: absent, request: .init(origin: .pointer))
        await waitUntil("new failure warns at menu bar") { button.toolTip?.contains(expectedLocalized("The device is offline", "设备已离线")) == true }
        button.performClick(nil)
        await waitUntil("opening restores current-output icon") { button.toolTip == "Test speaker" }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(button.toolTip, "Test speaker", "Preserved cause must not be replayed by opening refresh")
        XCTAssertEqual(store.feedbackKind, .failure)
        store.select(target: absent, request: .init(origin: .pointer))
        await waitUntil("same explicit failure alerts a second time") { button.toolTip?.contains(expectedLocalized("The device is offline", "设备已离线")) == true }
        XCTAssertTrue(hardware.selectedUIDs.isEmpty)
    }

    func testStatusButtonOpensClosesAndReopensNativePopover() async throws {
        let hardware = PopoverTestHardware()
        let routes = PopoverTestRoutes()
        let store = AudioStore(hardware: hardware, routes: routes)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let controller = StatusBarController(store: store, statusItem: item)
        defer {
            controller.stop()
            store.stop()
        }
        let button = try XCTUnwrap(item.button)
        await waitUntil("status button becomes a usable popover anchor") {
            button.window?.isVisible == true && !button.isHiddenOrHasHiddenAncestor
                && !button.bounds.intersection(button.visibleRect).isEmpty
        }
        let alreadyVisible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))

        button.performClick(nil)
        await waitUntil("first click displays a native popover") {
            self.newPopoverWindow(excluding: alreadyVisible, anchor: button.window) != nil
        }
        let firstWindow = try XCTUnwrap(newPopoverWindow(excluding: alreadyVisible, anchor: button.window))
        await waitUntil("opening refresh completes through the injected hardware") {
            hardware.snapshotCount > 0 && !store.isRefreshing
        }

        button.performClick(nil)
        await waitUntil("second click closes the popover") { !firstWindow.isVisible }

        button.performClick(nil)
        await waitUntil("third click reopens a native popover") {
            self.newPopoverWindow(excluding: alreadyVisible, anchor: button.window) != nil
        }
        let reopenedWindow = try XCTUnwrap(newPopoverWindow(excluding: alreadyVisible, anchor: button.window))
        XCTAssertFalse(reopenedWindow.ignoresMouseEvents)

        button.performClick(nil)
        await waitUntil("fourth click closes the reopened popover") { !reopenedWindow.isVisible }
        XCTAssertTrue(hardware.selectedUIDs.isEmpty, "Opening and closing must not change audio output.")
        XCTAssertTrue(routes.selectedIdentifiers.isEmpty)
    }

    private func newPopoverWindow(excluding visibleIDs: Set<ObjectIdentifier>, anchor: NSWindow?) -> NSWindow? {
        NSApp.windows.first {
            $0 !== anchor && !visibleIDs.contains(ObjectIdentifier($0))
                && $0.isVisible && $0.alphaValue >= 0.99 && !$0.ignoresMouseEvents
        }
    }

    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), description, file: file, line: line)
    }
}

@MainActor
private final class PopoverTestHardware: AudioHardwareProviding {
    private(set) var snapshotCount = 0
    private(set) var selectedUIDs: [String] = []
    var current = true
    nonisolated func beginShutdown() {}

    func snapshot() async throws -> CoreAudioSnapshot {
        snapshotCount += 1
        let speaker = AudioDevice(id: "hal:popover-test-speaker", name: "Test speaker", transport: .speaker,
                                  backend: .coreAudio(uid: "popover-test-speaker"))
        return CoreAudioSnapshot(devices: [speaker], currentDeviceID: current ? speaker.id : nil,
                                 systemSoundDeviceID: speaker.id, warnings: [])
    }

    func select(uid: String) async throws {
        selectedUIDs.append(uid)
        XCTFail("A status button toggle must not request an audio change.")
    }

    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws {}
    func stopObserving() async {}
}

@MainActor
private final class PopoverTestRoutes: PrivateRouting {
    var onChange: (() -> Void)?
    private(set) var selectedIdentifiers: [String] = []
    func start() {}
    func stop() {}
    func beginShutdown() {}
    func snapshot() -> PrivateRouteSnapshot { .init(routes: [], warning: nil, diagnostics: "popover test") }
    func select(identifier: String) async throws {
        selectedIdentifiers.append(identifier)
        XCTFail("A status button toggle must not select a route.")
    }
    func prepareToLeave() async throws { XCTFail("A status button toggle must not prepare an audio change.") }
    func completedLeave() async throws { XCTFail("A status button toggle must not clean up audio streams.") }
}
