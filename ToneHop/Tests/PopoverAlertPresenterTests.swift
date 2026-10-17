import AppKit
import XCTest
@testable import ToneHop

/// Uses ordinary AppKit windows; no status item, audio service, or saved binding
/// is involved. The native modal test stops itself from the modal run loop.
@MainActor
final class PopoverAlertPresenterTests: XCTestCase {
    func testMissingHostCancelsWithoutEnteringModalPresentation() async {
        let presenter = PopoverAlertPresenter()
        let alert = ObservedPopoverAlert(name: "Bedroom")
        alert.duringRunModal = { XCTFail("An alert without a host must not be presented.") }

        let response = await presenter.present(alert, host: { nil })

        XCTAssertEqual(response, .cancel)
        XCTAssertEqual(alert.modalRuns, 0)
        XCTAssertNil(alert.window.parent)
        XCTAssertFalse(alert.window.isVisible)
        XCTAssertFalse(presenter.owns(alert.window))
        XCTAssertFalse(presenter.owns(nil))
        XCTAssertFalse(presenter.isPresenting)
    }

    func testHiddenHostCancelsWithoutEnteringModalPresentation() async {
        let presenter = PopoverAlertPresenter()
        let host = makeHost()
        let alert = ObservedPopoverAlert(name: "Bedroom")
        alert.duringRunModal = { XCTFail("A closed popover must not acquire a confirmation window.") }

        let response = await presenter.present(alert, host: { host })

        XCTAssertEqual(response, .cancel)
        XCTAssertEqual(alert.modalRuns, 0)
        XCTAssertNil(alert.window.parent)
        XCTAssertTrue(host.childWindows?.isEmpty ?? true)
        XCTAssertFalse(presenter.owns(alert.window))
    }

    func testCancellationBeforeQueuedAppKitEntryPreventsPresentation() async {
        let presenter = PopoverAlertPresenter()
        let host = makeHost()
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let alert = ObservedPopoverAlert(name: "Bedroom")
        var cancellationDelivered = false
        alert.duringRunModal = { XCTFail("A cancelled queued request must not open its alert.") }

        // Both blocks run after this actor job yields. Put cancellation ahead
        // of the AppKit entry that present queues after capturing its revision.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                cancellationDelivered = true
                presenter.cancel()
            }
        }
        let response = await presenter.present(alert, host: { host })

        XCTAssertTrue(cancellationDelivered)
        XCTAssertEqual(response, .cancel)
        XCTAssertEqual(alert.modalRuns, 0)
        XCTAssertNil(alert.window.parent)
        XCTAssertFalse(alert.window.isVisible)
        XCTAssertFalse(presenter.owns(alert.window))
    }

    func testPresentationAttachesAboveHostAndRestoresWindowAfterButtonResponse() async {
        let presenter = PopoverAlertPresenter()
        let host = makeHost()
        host.level = .popUpMenu
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let alert = ObservedPopoverAlert(name: "Bedroom")
        let originalLevel = alert.window.level
        alert.response = .alertFirstButtonReturn
        alert.duringRunModal = {
            XCTAssertTrue(alert.window.parent === host)
            XCTAssertTrue(host.childWindows?.contains(where: { $0 === alert.window }) == true)
            XCTAssertGreaterThanOrEqual(alert.window.level.rawValue, host.level.rawValue)
            XCTAssertTrue(presenter.owns(alert.window))
            XCTAssertFalse(presenter.owns(host))
            XCTAssertTrue(presenter.isPresenting)
        }

        let response = await presenter.present(alert, host: { host })

        XCTAssertEqual(response, .alertFirstButtonReturn)
        XCTAssertEqual(alert.modalRuns, 1)
        XCTAssertNil(alert.window.parent)
        XCTAssertTrue(host.childWindows?.isEmpty ?? true)
        XCTAssertEqual(alert.window.level, originalLevel)
        XCTAssertFalse(alert.window.isVisible)
        XCTAssertFalse(presenter.owns(alert.window))
        XCTAssertFalse(presenter.isPresenting)
        XCTAssertTrue(host.isVisible)
    }

    func testNonactivatingHostRegainsRealKeyStatusBeforePresentationOwnershipEnds() async throws {
        let presenter = PopoverAlertPresenter()
        let host = makeNonactivatingHost()
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let alert = SelfStoppingPopoverAlert(name: "Nonactivating panel focus test")
        var observedHostKey = false
        var establishedInactiveState = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: host, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                observedHostKey = true
                XCTAssertTrue(presenter.isPresenting,
                    "The modal relationship must own focus until the host actually becomes key again.")
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        alert.duringModal = {
            XCTAssertTrue(presenter.isPresenting)
            XCTAssertTrue(NSApp.modalWindow === alert.window)
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        alert.afterModal = {
            // Establish the precondition after AppKit's modal loop returns but
            // before the presenter restores focus. Some hosted environments do
            // not honor self-deactivation, even after the native modal ends.
            XCTAssertNil(NSApp.modalWindow)
            NSApp.deactivate()
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while NSApp.isActive, ContinuousClock.now < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            establishedInactiveState = !NSApp.isActive
        }

        let response = await presenter.present(alert, host: { host })

        XCTAssertEqual(response, .alertFirstButtonReturn)
        XCTAssertTrue(host.isVisible)
        XCTAssertTrue(host.isKeyWindow, "A live nonactivating host must recover real keyboard focus.")
        XCTAssertTrue(observedHostKey)
        XCTAssertFalse(presenter.isPresenting)
        XCTAssertNil(alert.window.parent)
        try XCTSkipIf(!establishedInactiveState,
            "This environment did not honor native self-deactivation; inactive-app focus recovery was not exercised.")
    }

    func testCancelledPresentationDoesNotRestoreKeyToRetiredVisibleHost() async {
        let presenter = PopoverAlertPresenter()
        let host = makeNonactivatingHost()
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let alert = SelfStoppingPopoverAlert(name: "Retired panel focus test")
        var hostIsCurrent = true
        var restoredRetiredHostKey = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: host, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if !hostIsCurrent { restoredRetiredHostKey = true }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        alert.duringModal = {
            XCTAssertTrue(presenter.isPresenting)
            // Closing intent invalidates the supplied host immediately; its
            // native window may still be visible during the fade-out.
            hostIsCurrent = false
            presenter.cancel()
            XCTAssertTrue(presenter.isPresenting,
                "Cancellation must retain ownership until native modal cleanup returns.")
        }

        let response = await presenter.present(alert, host: { hostIsCurrent ? host : nil })

        XCTAssertEqual(response, .cancel)
        XCTAssertTrue(host.isVisible, "Cancellation must not order a retiring host back to the front.")
        XCTAssertFalse(restoredRetiredHostKey)
        XCTAssertFalse(presenter.isPresenting)
        XCTAssertNil(alert.window.parent)
        XCTAssertFalse(alert.window.isVisible)
    }

    func testNativeModalCancellationCleansUpAndAllowsAnotherPresentation() async {
        let presenter = PopoverAlertPresenter()
        let host = makeHost()
        host.level = .popUpMenu
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let alert = SelfStoppingPopoverAlert(name: "Modal lifecycle test")
        alert.duringModal = {
            XCTAssertTrue(NSApp.modalWindow === alert.window)
            XCTAssertTrue(alert.window.parent === host)
            XCTAssertGreaterThanOrEqual(alert.window.level.rawValue, host.level.rawValue,
                "runModal must not reset the confirmation below its popover host.")
            let order = NSWindow.windowNumbers(options: [])?.map(\.intValue) ?? []
            if let front = order.firstIndex(of: alert.window.windowNumber),
               let back = order.firstIndex(of: host.windowNumber) {
                XCTAssertLessThan(front, back, "The actual window-server order must put the alert first.")
            } else { XCTFail("Both native windows must be visible during the modal session.") }
            XCTAssertTrue(presenter.owns(alert.window))
            presenter.cancel()
        }

        let response = await presenter.present(alert, host: { host })

        XCTAssertEqual(response, .cancel)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertNil(alert.window.parent)
        XCTAssertTrue(host.childWindows?.isEmpty ?? true)
        // Native modal cleanup can reset a hidden NSPanel to the normal level
        // after present resumes. The non-native test above separately checks
        // our exact restore assignment; here verify no elevated window lingers.
        XCTAssertLessThan(alert.window.level.rawValue, host.level.rawValue)
        XCTAssertFalse(alert.window.isVisible)
        XCTAssertFalse(presenter.owns(alert.window))
        XCTAssertTrue(host.isVisible)

        let nextAlert = ObservedPopoverAlert(name: "Bedroom")
        nextAlert.response = .alertSecondButtonReturn
        let nextResponse = await presenter.present(nextAlert, host: { host })
        XCTAssertEqual(nextResponse, .alertSecondButtonReturn)
        XCTAssertEqual(nextAlert.modalRuns, 1, "Cancellation must release the active presentation slot.")
        XCTAssertNil(nextAlert.window.parent)
        XCTAssertFalse(presenter.owns(nextAlert.window))
    }

    func testNativeModalStaysCenteredAboveItsHostAsTheHostMovesAndResizes() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let visible = screen.visibleFrame
        let host = makeNonactivatingHost()
        host.setFrame(NSRect(x: visible.midX - 164, y: visible.midY - 220, width: 328, height: 440), display: false)
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let presenter = PopoverAlertPresenter()
        let alert = SelfStoppingPopoverAlert(name: "EDIFIER W820NB")
        alert.duringModal = {
            XCTAssertTrue(NSApp.modalWindow === alert.window)
            XCTAssertTrue(alert.window.isVisible)
            if NSApp.isActive { XCTAssertTrue(alert.window.isKeyWindow) }
            XCTAssertEqual(alert.window.frame.midX, host.frame.midX, accuracy: 0.5)
            XCTAssertEqual(alert.window.frame.midY, host.frame.midY + 20, accuracy: 0.5)
            XCTAssertTrue(host.frame.contains(alert.window.frame))

            host.setFrame(NSRect(x: visible.midX - 120, y: visible.midY - 160, width: 328, height: 320), display: false)
            XCTAssertEqual(alert.window.frame.midX, host.frame.midX, accuracy: 0.5)
            XCTAssertEqual(alert.window.frame.midY, host.frame.midY + 20, accuracy: 0.5)
            alert.cancelButton.performClick(nil)
        }

        let response = await presenter.present(alert, host: { host })

        XCTAssertEqual(response, .cancel)
        XCTAssertTrue(host.isKeyWindow)
        XCTAssertFalse(presenter.isPresenting)
    }

    func testNativeModalClampsToTheHostScreenWhenTheHostIsAtAnEdge() async throws {
        // Prefer an external display if available; the window's own screen is
        // the placement authority, independent of the app's main display.
        let screen = try XCTUnwrap(NSScreen.screens.last)
        let visible = screen.visibleFrame
        let host = makeNonactivatingHost()
        host.setFrame(NSRect(x: visible.minX, y: visible.maxY - 100, width: 100, height: 100), display: false)
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let presenter = PopoverAlertPresenter()
        let alert = SelfStoppingPopoverAlert(name: "Bedroom")
        alert.duringModal = {
            XCTAssertTrue(NSApp.modalWindow === alert.window)
            XCTAssertEqual(host.screen, screen)
            XCTAssertGreaterThanOrEqual(alert.window.frame.minX, visible.minX)
            XCTAssertLessThanOrEqual(alert.window.frame.maxX, visible.maxX)
            XCTAssertGreaterThanOrEqual(alert.window.frame.minY, visible.minY)
            XCTAssertLessThanOrEqual(alert.window.frame.maxY, visible.maxY)
            XCTAssertEqual(alert.window.frame.minX, visible.minX, accuracy: 0.5)
            XCTAssertEqual(alert.window.frame.maxY, visible.maxY, accuracy: 0.5)
            alert.window.close()
        }

        let response = await presenter.present(alert, host: { host })

        XCTAssertEqual(response, .cancel)
        XCTAssertNil(alert.window.parent)
        XCTAssertFalse(alert.window.isVisible)
        XCTAssertFalse(presenter.isPresenting)
    }

    func testRecordRemovalCopyIsLocalizedAndPreservesTheSavedName() {
        let name = "Bedroom 卧室 %@ 🎧"
        let alert = RecordRemovalAlerts.confirmation(name: name)
        XCTAssertEqual(alert.titleLabel.stringValue,
                       expectedLocalized("Remove the record for “\(name)”?",
                                         "移除「\(name)」的记录？"))
        XCTAssertEqual(alert.informativeLabel.stringValue,
                       expectedLocalized("This also clears its shortcut. Audio output stays unchanged.",
                                         "同时清除快捷键，不影响声音输出。"))
        XCTAssertEqual(alert.cancelButton.title, expectedLocalized("Cancel", "取消"))
        XCTAssertEqual(alert.removeButton.title, expectedLocalized("Remove", "移除"))
        XCTAssertEqual(alert.cancelButton.keyEquivalent, "\r")
    }

    func testCompactPanelKeepsLongNamesAccessibleWithoutOverlappingControls() {
        let ordinary = RecordRemovalAlerts.confirmation(name: "EDIFIER W820NB")
        let name = String(repeating: "会议室扬声器 Studio Display ", count: 12)
        let long = RecordRemovalAlerts.confirmation(name: name)

        XCTAssertLessThan(ordinary.window.frame.width, 300)
        XCTAssertLessThan(ordinary.window.frame.height, 170)
        XCTAssertEqual(long.window.frame.width, ordinary.window.frame.width)
        XCTAssertGreaterThan(long.window.frame.height, ordinary.window.frame.height)
        XCTAssertLessThan(long.window.frame.height, 210)
        XCTAssertEqual(long.titleLabel.toolTip, expectedLocalized("Remove the record for “\(name)”?", "移除「\(name)」的记录？"))
        XCTAssertEqual(long.titleLabel.accessibilityLabel(), long.titleLabel.toolTip)
        let controls: [NSView] = [long.titleLabel, long.informativeLabel, long.cancelButton, long.removeButton]
        guard let content = long.window.contentView else { return XCTFail("The confirmation needs visible content.") }
        let rects = controls.map { $0.convert($0.bounds, to: content) }
        for rect in rects {
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            XCTAssertTrue(content.bounds.contains(rect), "Every control must fit inside the compact confirmation.")
        }
        for index in rects.indices {
            for other in rects.indices where other > index {
                XCTAssertFalse(rects[index].intersects(rects[other]), "Long names cannot overlap the explanation or buttons.")
            }
        }
        XCTAssertTrue(long.removeButton.hasDestructiveAction)
    }

    func testNativeRemoveButtonReturnsConfirmationAndReleasesModalOwnership() async {
        let host = makeNonactivatingHost()
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let presenter = PopoverAlertPresenter()
        let alert = SelfStoppingPopoverAlert(name: "Bedroom")
        alert.duringModal = {
            XCTAssertTrue(NSApp.modalWindow === alert.window)
            alert.removeButton.performClick(nil)
        }

        let response = await presenter.present(alert, host: { host })

        XCTAssertEqual(response, .alertSecondButtonReturn)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertNil(alert.window.parent)
        XCTAssertFalse(presenter.isPresenting)
        XCTAssertTrue(host.isKeyWindow)
    }

    func testNativeEscapeAndReturnBothCancelInsteadOfRemoving() async throws {
        let host = makeNonactivatingHost()
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let presenter = PopoverAlertPresenter()
        for (characters, keyCode) in [("\u{1b}", UInt16(53)), ("\r", UInt16(36))] {
            let alert = SelfStoppingPopoverAlert(name: "Bedroom")
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: alert.window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
            alert.duringModal = {
                XCTAssertTrue(NSApp.modalWindow === alert.window)
                // Escape is a responder command, whereas Return is the default
                // button equivalent. Deliver the full local native key event so
                // both go through the same path as real keyboard input.
                alert.window.sendEvent(event)
            }

            let response = await presenter.present(alert, host: { host })

            XCTAssertEqual(response, .cancel, "Cancellation key code \(keyCode) must never remove a record.")
            XCTAssertNil(NSApp.modalWindow)
            XCTAssertNil(alert.window.parent)
            XCTAssertTrue(host.isKeyWindow)
        }
    }

    private func makeHost() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Popover alert test host"
        return window
    }

    private func makeNonactivatingHost() -> NSPanel {
        let panel = KeyCapablePopoverTestPanel(
            contentRect: NSRect(x: 80, y: 80, width: 320, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        return panel
    }
}

@MainActor
private final class KeyCapablePopoverTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The public modal entry remains the observation point, while avoiding UI for
/// fail-closed and window relationship checks.
@MainActor
private final class ObservedPopoverAlert: RecordRemovalPanel {
    var modalRuns = 0
    var response: NSApplication.ModalResponse = .cancel
    var duringRunModal: (() -> Void)?

    override func runModal() -> NSApplication.ModalResponse {
        modalRuns += 1
        duringRunModal?()
        return response
    }
}

@MainActor
private final class SelfStoppingPopoverAlert: RecordRemovalPanel {
    var duringModal: (() -> Void)?
    var afterModal: (() -> Void)?

    override func runModal() -> NSApplication.ModalResponse {
        let timer = Timer(timeInterval: 0.01, repeats: false) { [self] _ in
            MainActor.assumeIsolated { duringModal?() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let timeout = Timer(timeInterval: 2, repeats: false) { [self] _ in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow === window else { return }
                XCTFail("The native confirmation did not return after its test action.")
                NSApp.stopModal(withCode: .abort)
            }
        }
        RunLoop.main.add(timeout, forMode: .modalPanel)
        defer { timer.invalidate(); timeout.invalidate() }
        let response = super.runModal()
        afterModal?()
        return response
    }
}
