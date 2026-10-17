import AppKit
import OSLog
import Observation
import QuartzCore
import SwiftUI

enum PopoverEscapeRouting {
    enum Action: Equatable { case passThrough, cancelRecording, closePopover }

    static func action(isPopoverWindow: Bool, hasModalWindow: Bool,
                       isRecording: Bool, hasModifiers: Bool) -> Action {
        guard !hasModalWindow, isPopoverWindow else { return .passThrough }
        if isRecording { return hasModifiers ? .passThrough : .cancelRecording }
        return .closePopover
    }
}

/// AppKit owns only the menu-bar interaction and presentation lifecycle.
/// Audio state remains in the shared AudioStore read by the SwiftUI content.
@MainActor
final class StatusBarController: NSObject {
    private let store: AudioStore
    private let interactions: AudioInteractionCoordinator?
    private let statusItem: NSStatusItem
    private let popover: GlassPanelHost
    private let quitMenu: NSMenu
    private let deletionPresenter = PopoverAlertPresenter()
    private var localEventMonitor: Any?
    private var globalMouseMonitor: Any?
    private var isClosing = false
    private var isTransitioning = false
    private var wantsPopoverShown = false
    private var presentationRevision = 0
    private var stopped = false
    private var presentedFailures = Set<UUID>()
    private var warningMessage: String?
    private var failureResetTask: Task<Void, Never>?
    private var failureRevision = 0
    #if DEBUG
    private var debugPresentationTask: Task<Void, Never>?
    #endif
    private let logger = Logger(subsystem: "com.dengziyi.ToneHop", category: "MenuBar")

    static func makeQuitMenu() -> NSMenu {
        let menu = NSMenu()
        let quit = NSMenuItem(title: String(localized: "ui.quit.menu", defaultValue: "Quit"), action: #selector(quitApplication), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quit.image?.isTemplate = true
        menu.addItem(quit)
        return menu
    }

    static func shortcutConflict(_ shortcut: DeviceShortcut, quitMenu: NSMenu, mainMenu: NSMenu?) -> String? {
        ShortcutKeyDisplay.conflict(shortcut, menus: [quitMenu] + [mainMenu].compactMap { $0 })
    }

    init(store: AudioStore, interactions: AudioInteractionCoordinator? = nil,
         quitMenu: NSMenu = StatusBarController.makeQuitMenu(), statusItem: NSStatusItem? = nil) {
        self.store = store
        self.interactions = interactions
        self.quitMenu = quitMenu
        self.statusItem = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let content = NSHostingController(rootView: OutputDevicesView(store: store, interactions: interactions))
        self.popover = GlassPanelHost(content: content)
        super.init()

        if statusItem == nil { self.statusItem.autosaveName = "ToneHop.Output" }
        if let button = self.statusItem.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "ToneHop")
            button.image?.isTemplate = true
            button.toolTip = String(localized: "ui.status.tooltip", defaultValue: "ToneHop · Sound Output")
            button.setAccessibilityLabel(String(localized: "ui.status.label", defaultValue: "ToneHop, Sound Output"))
            // Own the toggle through the public button action. On this system,
            // repeated left clicks did not reach our expanded-session monitor.
            button.target = self
            button.action = #selector(statusButtonActivated)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        interactions?.cancelRecordRemoval = { [weak self] in self?.deletionPresenter.cancel() }
        interactions?.presentRecordRemoval = { [weak self] request in
            guard let self else { return false }
            let alert = RecordRemovalAlerts.confirmation(name: request.deviceName)
            return await self.deletionPresenter.present(alert, host: { [weak self] in
                guard let self, self.popover.isShown, self.wantsPopoverShown,
                      !self.isClosing, !self.store.isPreparingToQuit else { return nil }
                return self.popover.window
            }) == .alertSecondButtonReturn
        }
        popover.onWillClose = { [weak self] in self?.popoverWillClose() }
        popover.onDidClose = { [weak self] in self?.popoverDidClose() }

        for item in quitMenu.items where item.action == #selector(quitApplication) { item.target = self }

        installEventMonitors()
        NotificationCenter.default.addObserver(
            self, selector: #selector(dismissForFocusChange),
            name: NSApplication.didResignActiveNotification, object: NSApp
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(dismissForFocusChange),
            name: NSWindow.didResignKeyNotification, object: popover.window
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(dismissForFocusChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        observePresentation()
        logger.info("Menu bar ready: r08-glass-panel")
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        #if DEBUG
        cancelTestingPresentation()
        #endif
        wantsPopoverShown = false
        interactions?.cancelRecording()
        interactions?.onShortcutFailure = nil
        interactions?.presentRecordRemoval = nil
        interactions?.cancelRecordRemoval = nil
        deletionPresenter.cancel()
        failureResetTask?.cancel()
        presentationRevision += 1
        popover.close()
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    #if DEBUG
    func cancelTestingPresentation() {
        debugPresentationTask?.cancel()
        debugPresentationTask = nil
    }

    /// Explicit GUI-test entry; Release builds contain neither this method nor its caller.
    func showPopoverForTesting() {
        cancelTestingPresentation()
        debugPresentationTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            var attempts = 0
            while !Task.isCancelled, clock.now < deadline {
                guard let self, let button = self.statusItem.button else { return }
                // A main.async launch callback can still precede the menu bar
                // host's layout. AppKit cannot anchor to an empty visible rect.
                if button.window?.isVisible == true,
                   !button.isHiddenOrHasHiddenAncestor,
                   !button.bounds.intersection(button.visibleRect).isEmpty {
                    attempts += 1
                    self.showPopover(from: button)
                    if self.popover.isShown {
                        self.logger.info("Debug GUI entry ready: attempts=\(attempts)")
                        return
                    }
                }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            let button = self.statusItem.button
            self.logger.error("Debug GUI entry timed out: attempts=\(attempts), windowVisible=\(button?.window?.isVisible ?? false), bounds=\(String(describing: button?.bounds), privacy: .public), visibleRect=\(String(describing: button?.visibleRect), privacy: .public)")
        }
    }
    #endif

    @objc private func statusButtonActivated() {
        #if DEBUG
        // An explicit user click takes over from the one-shot test launch.
        cancelTestingPresentation()
        #endif
        guard !stopped, let button = statusItem.button else { return }
        // A status-item click cancels this confirmation before toggling its host.
        deletionPresenter.cancel()
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        logger.info("Status button action: context=\(isContextClick), shown=\(self.popover.isShown), wantsShown=\(self.wantsPopoverShown), transitioning=\(self.isTransitioning)")

        if isContextClick, let event {
            interactions?.setMenuTracking(true)
            defer { interactions?.setMenuTracking(false) }
            closePopover(reason: "context menu", animated: false)
            NSMenu.popUpContextMenu(quitMenu, with: event, for: button)
        } else if wantsPopoverShown {
            closePopover(reason: "status button toggle")
        } else {
            showPopover(from: button)
        }
    }

    private func showPopover(from button: NSStatusBarButton) {
        guard !stopped else { return }
        restoreStatusIcon()
        wantsPopoverShown = true
        presentationRevision += 1
        let revision = presentationRevision
        isClosing = false
        store.refresh()
        // The nonactivating panel obtains key status itself. Do not initiate a
        // second application-activation transition while its glass is visible.
        popover.show(from: button)
        guard !stopped, wantsPopoverShown, presentationRevision == revision else { return }
        button.highlight(true)
        animate(popover.window, visible: true)
        logger.info("Popover opening: active=\(NSApp.isActive), key=\(self.popover.window.isKeyWindow)")
    }

    private func closePopover(reason: String, animated: Bool = true) {
        deletionPresenter.cancel()
        interactions?.cancelRecording()
        wantsPopoverShown = false
        presentationRevision += 1
        statusItem.button?.highlight(false)
        guard popover.isShown else { return }
        isClosing = true
        logger.info("Popover close requested: \(reason, privacy: .public)")
        guard animated else {
            popover.close()
            return
        }
        let window = popover.window
        // Prevent an accidental device selection while the panel is leaving.
        window.ignoresMouseEvents = true
        animate(window, visible: false)
    }

    private func animate(_ window: NSWindow, visible: Bool) {
        let revision = presentationRevision
        isTransitioning = true
        popover.animate(visible: visible) { [weak self] in
            guard let self, !self.stopped, self.presentationRevision == revision else { return }
            self.isTransitioning = false
            if !visible { self.popover.close() }
        }
    }

    private func popoverWillClose() {
        deletionPresenter.cancel()
        interactions?.cancelRecording()
        statusItem.button?.highlight(false)
        logger.info("Popover will close")
    }

    private func popoverDidClose() {
        let reopen = isClosing && wantsPopoverShown
        presentationRevision += 1
        isClosing = false
        isTransitioning = false
        wantsPopoverShown = false
        popover.window.alphaValue = 1
        popover.window.ignoresMouseEvents = false
        logger.info("Popover did close")
        if reopen, let button = statusItem.button {
            showPopover(from: button)
        }
    }

    private func installEventMonitors() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                // Modal cancellation owns Escape even with the popover behind it.
                switch PopoverEscapeRouting.action(
                    isPopoverWindow: event.window === self.popover.window,
                    hasModalWindow: NSApp.modalWindow != nil,
                    isRecording: self.interactions?.shortcuts.isRecording == true,
                    hasModifiers: !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                ) {
                case .passThrough: return event
                case .cancelRecording:
                    self.interactions?.cancelRecording()
                    return nil
                case .closePopover:
                    self.closePopover(reason: "Escape")
                    return nil
                }
            }

            // Let the status button action handle its own complete click.
            if self.deletionPresenter.owns(event.window) { return event }
            if self.isPointerOverStatusButton {
                return event
            }
            if event.window !== self.popover.window {
                self.closePopover(reason: "local outside click")
            }
            return event
        }

        // Mouse-only observation does not require Accessibility permission.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, !self.isPointerOverStatusButton else { return }
            self.closePopover(reason: "global outside click")
        }
    }

    private var isPointerOverStatusButton: Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return rect.contains(NSEvent.mouseLocation)
    }

    @objc private func dismissForFocusChange(_ notification: Notification) {
        guard !stopped, wantsPopoverShown, !isClosing else { return }
        // A nonactivating panel can lose keyboard focus while NSApp stays
        // inactive. Its own modal confirmation temporarily owns that handoff.
        if notification.name == NSWindow.didResignKeyNotification,
           deletionPresenter.isPresenting { return }
        // A click on the status item can resign app activation before the
        // button's mouse-up action. Let that action own the entire click, just
        // as the outside-click monitors do; keyboard/Space changes still close.
        if notification.name != NSWorkspace.activeSpaceDidChangeNotification,
           isPointerOverStatusButton, NSEvent.pressedMouseButtons & 0b11 != 0 {
            logger.info("Focus dismissal deferred to status button action")
            return
        }
        logger.debug("Focus event: name=\(notification.name.rawValue, privacy: .public), anchor=\(self.isPointerOverStatusButton), pressedButtons=\(NSEvent.pressedMouseButtons), eventType=\(NSApp.currentEvent?.type.rawValue ?? 0)")
        closePopover(
            reason: notification.name == NSWorkspace.activeSpaceDidChangeNotification ? "Space changed" : "presentation lost focus",
            animated: notification.name != NSWorkspace.activeSpaceDidChangeNotification
        )
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    /// Observation tracks only immutable presentation values from the stores.
    /// Re-arm after each delivery and stop permanently with this controller.
    private func observePresentation() {
        guard !stopped else { return }
        withObservationTracking {
            updateStatusPresentation()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePresentation() }
        }
    }

    private func updateStatusPresentation() {
        let failures = [store.failureEvent, interactions?.volume.failureEvent,
                        interactions?.shortcuts.failureEvent].compactMap { $0 }
        let ids = Set(failures.map(\.id))
        if let event = failures.last(where: { !presentedFailures.contains($0.id) }) {
            showFailure(event.message)
        }
        presentedFailures = ids
        renderStatusIcon()
    }

    private func showFailure(_ reason: String) {
        guard !stopped else { return }
        failureResetTask?.cancel()
        failureRevision += 1
        let revision = failureRevision
        warningMessage = reason
        renderStatusIcon()
        failureResetTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, !self.stopped, self.failureRevision == revision else { return }
            self.restoreStatusIcon()
        }
    }

    private func restoreStatusIcon() {
        failureResetTask?.cancel()
        failureResetTask = nil
        failureRevision += 1
        warningMessage = nil
        renderStatusIcon()
    }

    private func renderStatusIcon() {
        guard !stopped else { return }
        let current = store.devices.first { $0.id == store.currentDeviceID }
        let speaker = NSImage(systemSymbolName: DeviceIconRendering.symbolName(for: current?.icon ?? .fallback),
                              accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        if warningMessage != nil {
            let badge = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
            let symbol = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
                speaker?.draw(in: NSRect(x: 0, y: 2, width: 15, height: 14))
                badge?.draw(in: NSRect(x: 12, y: 0, width: 8, height: 8))
                return true
            }
            symbol.isTemplate = true
            statusItem.button?.image = symbol
        } else {
            speaker?.isTemplate = true
            statusItem.button?.image = speaker
        }
        let output = current?.name ?? String(localized: "ui.status.unconfirmed", defaultValue: "Current output is not yet confirmed")
        statusItem.button?.toolTip = [output, warningMessage].compactMap { $0 }.joined(separator: "\n")
        statusItem.button?.setAccessibilityLabel(warningMessage == nil
            ? String(localized: "ui.status.output", defaultValue: "ToneHop, \(output)")
            : String(localized: "ui.status.output_warning", defaultValue: "ToneHop, \(output), open to view the message"))
    }
}
