import AppKit
import OSLog

/// Owns the short-lived native modal relationship, on the AppKit thread only.
/// The caller supplies the actual popover window when presentation starts.
@MainActor
final class PopoverAlertPresenter {
    private var activeAlert: RecordRemovalPanel?
    private var presentationRevision = 0
    private let logger = Logger(subsystem: "com.dengziyi.ToneHop", category: "MenuBar")

    // Focus can leave the host before AppKit identifies the new key window.
    // Keep the whole modal handoff owned until focus is returned to the host.
    var isPresenting: Bool { activeAlert != nil }

    func owns(_ window: NSWindow?) -> Bool {
        guard let window, let activeAlert else { return false }
        return window === activeAlert.window
    }

    func present(_ alert: RecordRemovalPanel, host: @escaping @MainActor () -> NSWindow?) async -> NSApplication.ModalResponse {
        let revision = presentationRevision
        return await withCheckedContinuation { continuation in
            // runModal must start outside an executing Swift actor job.
            RunLoop.main.perform(inModes: [.common]) { [self] in
                MainActor.assumeIsolated {
                    guard self.presentationRevision == revision,
                          self.activeAlert == nil, NSApp.modalWindow == nil,
                          let parent = host(), parent.isVisible else {
                        continuation.resume(returning: .cancel)
                        return
                    }
                    self.activeAlert = alert
                    let window = alert.window
                    let originalLevel = window.level
                    window.level = max(window.level, parent.level)
                    parent.addChildWindow(window, ordered: .above)
                    Self.position(window, over: parent)
                    let reconcileOrdering: @MainActor () -> Void = { [weak self, logger = self.logger] in
                        guard self?.presentationRevision == revision,
                              self?.activeAlert === alert, window.parent === parent,
                              parent.isVisible else { return }
                        // Reconcile after AppKit enters its native modal loop,
                        // including reactivation and changes to the host frame.
                        window.level = max(window.level, parent.level)
                        Self.position(window, over: parent)
                        window.order(.above, relativeTo: parent.windowNumber)
                        #if DEBUG
                        let order = NSWindow.windowNumbers(options: [])?.map(\.intValue) ?? []
                        let alertIndex = order.firstIndex(of: window.windowNumber)
                        let hostIndex = order.firstIndex(of: parent.windowNumber)
                        let above = alertIndex.flatMap { a in hostIndex.map { a < $0 } } ?? false
                        logger.notice("Shortcut confirmation visible: parentLevel=\(parent.level.rawValue), alertLevel=\(window.level.rawValue), attached=\(window.parent === parent), aboveHost=\(above), hostVisible=\(parent.isVisible)")
                        #endif
                    }
                    let observations = [
                        (NSWindow.didBecomeKeyNotification, window as NSWindow),
                        (NSWindow.didMoveNotification, parent),
                        (NSWindow.didResizeNotification, parent)
                    ].map { name, observedWindow in
                        NotificationCenter.default.addObserver(
                            forName: name, object: observedWindow, queue: .main
                        ) { _ in MainActor.assumeIsolated { reconcileOrdering() } }
                    }
                    defer { observations.forEach(NotificationCenter.default.removeObserver) }
                    // Activation can complete after the first modal event. Keep
                    // ordering correct even before didBecomeKey is delivered.
                    let orderingTimer = Timer(timeInterval: 0, repeats: false) { _ in
                        MainActor.assumeIsolated { reconcileOrdering() }
                    }
                    RunLoop.main.add(orderingTimer, forMode: .modalPanel)
                    defer { orderingTimer.invalidate() }
                    NSApp.activate()
                    self.logger.debug("Shortcut confirmation attached: parentLevel=\(parent.level.rawValue), alertLevel=\(window.level.rawValue)")
                    // Activation can synchronously invalidate the host before
                    // a modal window exists for cancel() to stop.
                    let response = self.presentationRevision == revision && host() === parent && parent.isVisible
                        ? alert.runModal() : .cancel
                    parent.removeChildWindow(window)
                    window.orderOut(nil)
                    window.level = originalLevel
                    if parent.isVisible, host() === parent,
                       NSApp.isActive || parent.styleMask.contains(.nonactivatingPanel) {
                        parent.makeKey()
                    }
                    self.activeAlert = nil
                    continuation.resume(returning: self.presentationRevision == revision ? response : .cancel)
                }
            }
        }
    }

    private static func position(_ window: NSWindow, over host: NSWindow) {
        let frame = host.frame
        let size = window.frame.size
        // Keep the confirmation visually attached to its host. Short hosts do
        // not have to push the confirmation outside their top edge to offset it.
        let upwardOffset = min(20, max(0, (frame.height - size.height) / 2))
        var origin = NSPoint(x: frame.midX - size.width / 2,
                             y: frame.midY - size.height / 2 + upwardOffset)
        if let visible = host.screen?.visibleFrame {
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        window.setFrameOrigin(origin)
    }

    func cancel() {
        presentationRevision += 1
        guard let activeAlert, NSApp.modalWindow === activeAlert.window else { return }
        NSApp.stopModal(withCode: .cancel)
        activeAlert.window.orderOut(nil)
    }
}
