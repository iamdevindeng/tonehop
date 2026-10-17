import AppKit
import QuartzCore
import SwiftUI

/// One system glass surface and its content move and fade as a single panel.
/// Content keeps its natural size; audio and editing state stay in stores.
@MainActor
final class GlassPanelHost {
    let window: NSPanel = OutputPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
    let contentViewController: NSViewController
    private let container = NSViewController()
    private let glass = NSGlassEffectView()
    private let canvas = NSView()
    private let contentHolder = NSView()
    private weak var anchor: NSStatusBarButton?
    private var sizeUpdateTask: Task<Void, Never>?
    private var pendingContentSize: NSSize?
    private var transitionRevision = 0
    private struct Transition {
        let visible: Bool
        let reduceMotion: Bool
        let deadline: CFTimeInterval
        let completion: @MainActor () -> Void
    }
    private var transition: Transition?
    private var naturalSize = NSSize.zero
    private var restingOrigin = NSPoint.zero
    private var desiredVisible = false
    private let travel: CGFloat = 5
    var onWillClose: (() -> Void)?
    var onDidClose: (() -> Void)?
    var isShown: Bool { window.isVisible }

    init(content: NSHostingController<OutputDevicesView>) {
        contentViewController = content
        content.sizingOptions = [.preferredContentSize]
        window.isOpaque = false
        window.backgroundColor = .clear
        // Let the single glass surface own its edge; do not add a second
        // window-shadow outline around the full transparent host.
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // A menu-bar panel needs keyboard focus without activating its app.
        // Acquire it on opening, before glass is revealed, not on the first
        // click inside the panel. Keep this style fixed for the window lifetime.
        window.becomesKeyOnlyIfNeeded = false
        window.level = .popUpMenu
        window.animationBehavior = .none
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true
        container.view = canvas
        container.addChild(content)
        window.contentViewController = container
        glass.style = .regular
        glass.cornerRadius = 24
        glass.wantsLayer = true
        // The whole panel owns the transition; interaction must not deform a
        // second glass surface independently of the text and controls.
        glass.contentView = contentHolder
        canvas.addSubview(glass)
        contentHolder.addSubview(content.view)
        content.view.autoresizingMask = []
        content.view.wantsLayer = true
        contentHolder.wantsLayer = true
        // The glass corner radius does not guarantee clipping of its content.
        // Constrain hosted content without clipping the system glass edge.
        contentHolder.layer?.cornerRadius = glass.cornerRadius
        contentHolder.layer?.cornerCurve = .continuous
        contentHolder.layer?.masksToBounds = true
        content.rootView.onContentSizeChange = { [weak self] size in
            self?.scheduleSizeUpdate(size)
        }
        updateSize()
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
        desiredVisible = true
        updateSize()
        if !window.isVisible {
            window.alphaValue = 0
            window.setFrameOrigin(restingOrigin.offsetBy(dy: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : travel))
        }
        window.ignoresMouseEvents = false
        window.makeKeyAndOrderFront(nil)
    }

    func animate(visible: Bool,
                 reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                 completion: @escaping @MainActor () -> Void) {
        let duration: TimeInterval = reduceMotion ? 0.14 : (visible ? 0.20 : 0.16)
        runTransition(Transition(visible: visible, reduceMotion: reduceMotion,
                                 deadline: CACurrentMediaTime() + duration, completion: completion))
    }

    private func runTransition(_ next: Transition) {
        let visible = next.visible
        let reduceMotion = next.reduceMotion
        let completion = next.completion
        transitionRevision += 1
        let revision = transitionRevision
        transition = next
        desiredVisible = visible
        window.ignoresMouseEvents = !visible
        // Content can report every frame of a disclosure animation. Retarget
        // the anchor without repeatedly restarting the open/close duration.
        let duration = max(0, next.deadline - CACurrentMediaTime())
        let finished: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.transitionRevision == revision else { return }
                self.transition = nil
                completion()
            }
        }
        // AppKit retargets an animating property from its current value. Window
        // opacity includes the glass and content, so no empty shell remains.
        // No bounds or transform animation is applied to the text or controls.
        if reduceMotion { window.setFrameOrigin(restingOrigin) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeInEaseOut)
            window.animator().alphaValue = visible ? 1 : 0
            if !reduceMotion {
                window.animator().setFrame(
                    NSRect(origin: restingOrigin.offsetBy(dy: visible ? 0 : travel), size: naturalSize),
                    display: false
                )
            }
        } completionHandler: { finished() }
    }

    func close() {
        transitionRevision += 1
        transition = nil
        desiredVisible = false
        guard window.isVisible else { return }
        onWillClose?()
        // A zero-duration animator update stops earlier property animations;
        // their completion handlers are rejected by the revision above.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = 0
            window.animator().setFrame(NSRect(origin: restingOrigin, size: naturalSize), display: false)
        }
        window.orderOut(nil)
        window.ignoresMouseEvents = false
        window.alphaValue = 1
        glass.frame = fullFrame
        contentViewController.view.alphaValue = 1
        onDidClose?()
    }

    private var fullFrame: NSRect { NSRect(origin: .zero, size: naturalSize) }

    private func scheduleSizeUpdate(_ size: NSSize) {
        // The fixed-size SwiftUI root reports its actual layout size. Reconcile
        // on the next actor turn to avoid re-entering that layout pass, keeping
        // only the newest report if SwiftUI lays out again before delivery.
        pendingContentSize = size
        guard sizeUpdateTask == nil else { return }
        sizeUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.sizeUpdateTask = nil
            let size = self.pendingContentSize
            self.pendingContentSize = nil
            self.updateSize(reportedSize: size)
        }
    }

    private func updateSize(reportedSize: NSSize? = nil) {
        let preferred = reportedSize ?? contentViewController.preferredContentSize
        let proposed = preferred.width > 0 && preferred.height > 0
            ? preferred : contentViewController.view.fittingSize
        guard proposed.width > 0, proposed.height > 0 else { return }
        let changed = naturalSize != proposed
        let visibleOffset = window.frame.minY - restingOrigin.y
        naturalSize = proposed
        restingOrigin = anchoredOrigin ?? restingOrigin
        if changed {
            // Resize and reanchor in one update. Intermediate SwiftUI layout
            // sizes already carry the animation; the glass must not lag behind
            // through an independent implicit layer or window resize animation.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let offset = window.isVisible && transition != nil ? visibleOffset : 0
            window.setFrame(NSRect(origin: restingOrigin.offsetBy(dy: offset), size: naturalSize), display: false)
            contentViewController.view.frame = fullFrame
            contentHolder.frame = fullFrame
            canvas.frame = fullFrame
            glass.frame = fullFrame
            CATransaction.commit()
        }
        if window.isVisible, let transition {
            guard changed else { return }
            // Changing natural height moves the resting origin to keep the
            // top edge anchored. Preserve only the ongoing 5pt travel offset.
            window.setFrameOrigin(restingOrigin.offsetBy(dy: visibleOffset))
            runTransition(transition)
        } else if !window.isVisible || desiredVisible {
            window.setFrameOrigin(restingOrigin)
        }
    }

    private var anchoredOrigin: NSPoint? {
        guard let button = anchor, let parent = button.window,
              let screen = parent.screen else { return nil }
        let rect = parent.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let x = min(max(rect.midX - naturalSize.width / 2, visible.minX + 8),
                    visible.maxX - naturalSize.width - 8)
        let y = max(visible.minY + 8, rect.minY - naturalSize.height - 8)
        return NSPoint(x: x, y: y)
    }
}

private extension NSPoint {
    func offsetBy(dy: CGFloat) -> NSPoint { NSPoint(x: x, y: y + dy) }
}

@MainActor
private final class OutputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
