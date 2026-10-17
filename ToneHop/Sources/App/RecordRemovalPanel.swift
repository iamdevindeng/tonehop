import AppKit

/// A compact native confirmation surface. Only the user's modal response leaves
/// this object; record validity and persistence remain in ShortcutStore.
@MainActor
class RecordRemovalPanel: NSObject {
    let window: NSPanel
    let titleLabel: NSTextField
    let informativeLabel: NSTextField
    let cancelButton: NSButton
    let removeButton: NSButton

    init(name: String) {
        window = RecordRemovalWindow(contentRect: .zero, styleMask: [.borderless],
                                     backing: .buffered, defer: false)
        titleLabel = NSTextField(wrappingLabelWithString: String(localized: "ui.record.remove_title", defaultValue: "Remove the record for “\(name)”?"))
        informativeLabel = NSTextField(wrappingLabelWithString: String(localized: "ui.record.remove_message", defaultValue: "This also clears its shortcut. Audio output stays unchanged."))
        cancelButton = NSButton(title: String(localized: "ui.cancel", defaultValue: "Cancel"), target: nil, action: nil)
        removeButton = NSButton(title: String(localized: "ui.record.remove", defaultValue: "Remove"), target: nil, action: nil)
        super.init()

        window.title = titleLabel.stringValue
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isMovableByWindowBackground = true
        window.animationBehavior = .none
        window.level = .modalPanel
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        let width: CGFloat = 276
        let inset: CGFloat = 18
        let textWidth = width - 2 * inset
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.maximumNumberOfLines = 3
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.toolTip = titleLabel.stringValue
        titleLabel.setAccessibilityLabel(titleLabel.stringValue)
        informativeLabel.font = .systemFont(ofSize: 12)
        informativeLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, informativeLabel] {
            label.preferredMaxLayoutWidth = textWidth
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        for button in [cancelButton, removeButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\r"
        removeButton.action = #selector(remove)
        removeButton.hasDestructiveAction = true
        // Standalone rounded buttons do not consistently apply destructive
        // tint to their title. Keep the native bezel and color its text with
        // the system's semantic destructive color instead.
        removeButton.attributedTitle = NSAttributedString(string: removeButton.title, attributes: [
            .font: removeButton.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.systemRed
        ])
        // Return chooses the safe action. Escape reaches the window's native
        // cancelOperation responder path rather than a second key equivalent.
        window.defaultButtonCell = cancelButton.cell as? NSButtonCell
        window.initialFirstResponder = cancelButton
        cancelButton.nextKeyView = removeButton
        removeButton.nextKeyView = cancelButton

        let buttons = NSStackView(views: [cancelButton, removeButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        let stack = NSStackView(views: [titleLabel, informativeLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: informativeLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            informativeLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        let size = NSSize(width: width, height: ceil(content.fittingSize.height))
        content.frame = NSRect(origin: .zero, size: size)
        content.autoresizingMask = [.width, .height]
        let glass = NSGlassEffectView(frame: content.frame)
        glass.style = .regular
        glass.cornerRadius = 20
        glass.contentView = content
        window.contentView = glass
        window.setContentSize(size)
        content.layoutSubtreeIfNeeded()
    }

    func runModal() -> NSApplication.ModalResponse {
        NSApp.runModal(for: window)
    }

    @objc private func cancel() { finish(with: .cancel) }
    @objc private func remove() { finish(with: .alertSecondButtonReturn) }

    private func finish(with response: NSApplication.ModalResponse) {
        guard NSApp.modalWindow === window else { return }
        NSApp.stopModal(withCode: response)
    }
}

@MainActor
private final class RecordRemovalWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        guard NSApp.modalWindow === self else { return }
        NSApp.stopModal(withCode: .cancel)
    }

    override func close() {
        if NSApp.modalWindow === self { NSApp.stopModal(withCode: .cancel) }
        super.close()
    }
}
