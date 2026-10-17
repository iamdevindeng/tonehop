import AppKit
import Carbon.HIToolbox
import SwiftUI

/// AppKit owns focus and key capture only. The Store owns editing, validation,
/// registration, persistence and all effects of accepting/cancelling a draft.
@MainActor
struct ShortcutRecorderView: NSViewRepresentable {
    let store: ShortcutStore
    let target: AudioTargetIdentity
    let deviceName: String

    func makeNSView(context: Context) -> ShortcutRecordingButton {
        let button = ShortcutRecordingButton()
        configure(button)
        return button
    }

    func updateNSView(_ button: ShortcutRecordingButton, context: Context) { configure(button) }

    private func configure(_ button: ShortcutRecordingButton) {
        let binding = store.binding(for: target)
        button.shortcut = binding?.shortcut
        if let binding, case let .failed(reason) = store.registrationStates[binding.id] {
            button.registrationFailure = reason
        } else { button.registrationFailure = nil }
        button.recording = store.isRecording(target: target)
        button.rowIssue = store.rowIssue(for: target)
        button.draftLabel = store.rowDraftLabel(for: target)
        button.isEnabled = store.canRecord(target: target)
        button.setAccessibilityLabel(String(localized: "ui.shortcut.label", defaultValue: "Shortcut for \(deviceName)"))
        button.setAccessibilityHelp(String(localized: "ui.shortcut.help", defaultValue: "Click to record a shortcut with Command or Control. Backspace clears it; Escape cancels."))
        button.onBegin = { store.beginRecording(target: target, deviceName: deviceName) }
        button.onCancel = { if store.isRecording(target: target) { store.cancelRecording() } }
        // Accepted input ends key capture; the Store disables editing and shows
        // save progress until asynchronous persistence confirms the binding.
        button.onKey = { shortcut in store.commitRecording(shortcut) }
        button.onError = { store.recordingRejected($0) }
        button.onClear = { store.clearRecording() }
        button.refreshTitle()
    }

    static func dismantleNSView(_ button: ShortcutRecordingButton, coordinator: ()) {
        button.cancelSession()
        button.onBegin = nil
        button.onCancel = nil
        button.onKey = nil
        button.onError = nil
        button.onClear = nil
    }
}

@MainActor
final class ShortcutRecordingButton: NSButton {
    var shortcut: DeviceShortcut?
    var registrationFailure: String?
    var rowIssue: String?
    var draftLabel: String?
    var recording = false
    var onBegin: (() -> Bool)?
    var onCancel: (() -> Void)?
    var onKey: ((DeviceShortcut) -> Bool)?
    var onError: (((any Error)) -> Void)?
    var onClear: (() -> Bool)?
    private var inputMonitor: Any?
    private var inputSourceObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        isBordered = false
        controlSize = .small
        font = .systemFont(ofSize: 11)
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginSession)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTitle() }
        }
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(cell?.isHighlighted == true ? 0.35 : 0.15).setFill()
        path.fill()
        let isFocused = window?.firstResponder === self
        let border: NSColor = rowIssue != nil ? .systemOrange : (recording || isFocused ? .systemBlue : .separatorColor)
        border.withAlphaComponent(isEnabled ? 0.8 : 0.35).setStroke()
        path.lineWidth = rowIssue != nil || recording || isFocused ? 1.25 : 0.75
        path.stroke()
        super.draw(dirtyRect)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    @objc private func beginSession() {
        guard !recording, let window, onBegin?() == true else { return }
        recording = true
        guard window.makeFirstResponder(self) else {
            cancelSession()
            return
        }
        // A local monitor wins before Command key equivalents reach menus. It
        // exists only while this control is the active first responder.
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, self.recording else { return event }
            guard event.window === self.window, self.window?.firstResponder === self else {
                self.cancelSession()
                return event
            }
            if event.type == .keyDown { return self.capture(event) ? nil : event }
            let point = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(point) { self.cancelSession() }
            return event
        }
        refreshTitle()
    }

    override func keyDown(with event: NSEvent) {
        if recording, capture(event) { return }
        if !recording, event.keyCode == 36 || event.keyCode == 49 { beginSession(); return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording, window?.firstResponder === self { return capture(event) }
        return super.performKeyEquivalent(with: event)
    }

    private func capture(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, recording else { return false }
        do {
            switch try ShortcutRecordingInput.decode(keyCode: event.keyCode, flags: event.modifierFlags,
                                                      isRepeat: event.isARepeat) {
            case .ignore: break
            case .cancel: cancelSession()
            case .navigate: cancelSession(); return false
            case .clear:
                if onClear?() == true { finishCapture() }
            case let .shortcut(shortcut):
                if onKey?(shortcut) == true { finishCapture() }
            }
        } catch { onError?(error) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        cancelSession()
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, window !== newWindow { cancelSession() }
        super.viewWillMove(toWindow: newWindow)
    }

    func cancelSession() {
        let wasRecording = recording
        finishCapture()
        if wasRecording { onCancel?() }
    }

    private func finishCapture() {
        recording = false
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
        refreshTitle()
    }

    func refreshTitle() {
        // Store cancellation can arrive through popover/exit before the next key.
        if !recording, let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
        title = recording ? (draftLabel ?? String(localized: "ui.shortcut.record", defaultValue: "Record…")) : shortcut.map(ShortcutKeyDisplay.label) ?? String(localized: "ui.shortcut.unset", defaultValue: "Not Set")
        image = nil
        if let issue = rowIssue ?? registrationFailure {
            toolTip = "\(title)：\(issue)"
            setAccessibilityValue("\(title)，\(issue)")
        } else {
            toolTip = recording ? String(localized: "ui.shortcut.record_help", defaultValue: "Command or Control + a regular or function key; ⌫ clears, Esc cancels") : title
            setAccessibilityValue(title)
        }
        needsDisplay = true
    }

    isolated deinit {
        if recording { onCancel?() }
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        if let inputSourceObserver { DistributedNotificationCenter.default().removeObserver(inputSourceObserver) }
    }
}

enum ShortcutRecordingInput: Equatable {
    case ignore, cancel, navigate, clear, shortcut(DeviceShortcut)

    static func decode(keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool) throws -> Self {
        if isRepeat { return .ignore }
        let modifiers = flags.intersection([.command, .control, .option, .shift])
        if keyCode == 53, modifiers.isEmpty { return .cancel }
        if keyCode == 48, modifiers.intersection([.command, .control]).isEmpty { return .navigate }
        if keyCode == 51, modifiers.isEmpty, !flags.contains(.function) { return .clear }
        return .shortcut(try DeviceShortcut(keyCode: keyCode, appKitFlags: flags))
    }
}

extension DeviceShortcut {
    init(keyCode: UInt16, appKitFlags flags: NSEvent.ModifierFlags) throws {
        let normalized = flags.intersection(.deviceIndependentFlagsMask)
        let allowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .capsLock, .numericPad, .function, .help]
        guard normalized.subtracting(allowed).isEmpty,
              !normalized.contains(.function) || Self.keysWithSynthesizedFunctionFlag.contains(keyCode) else {
            throw ShortcutError.unsupportedModifiers
        }
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        // Caps Lock state, keypad markers and synthetic Fn are not binding modifiers.
        try self.init(keyCode: keyCode, modifiers: modifiers)
    }
}

@MainActor
enum ShortcutKeyDisplay {
    static func label(_ shortcut: DeviceShortcut) -> String { shortcut.modifiers.symbols + keyName(shortcut.keyCode) }

    static func keyName(_ keyCode: UInt16) -> String {
        if let special = specialNames[keyCode] { return special }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard CFGetTypeID(data) == CFDataGetTypeID(), CFDataGetLength(data) > 0,
              let bytes = CFDataGetBytePtr(data) else { return "Key \(keyCode)" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey,
                                    characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    /// All menu trees used by the app must be supplied, including the status menu.
    static func conflict(_ shortcut: DeviceShortcut, menus: [NSMenu]) -> String? {
        let key = menuKey(shortcut.keyCode)
        for menu in menus {
            for item in menu.items {
                if let submenu = item.submenu, let match = conflict(shortcut, menus: [submenu]) { return match }
                guard !item.keyEquivalent.isEmpty else { continue }
                let flags = item.keyEquivalentModifierMask
                if let candidate = try? DeviceShortcut(keyCode: shortcut.keyCode, appKitFlags: flags),
                   candidate.modifiers == shortcut.modifiers,
                   item.keyEquivalent.lowercased() == key.lowercased() { return item.title }
            }
        }
        return nil
    }

    private static func menuKey(_ keyCode: UInt16) -> String {
        let values: [UInt16: UInt32] = [36: 13, 48: 9, 49: 32, 51: 8, 53: 27, 76: 3,
            115: 0xF729, 116: 0xF72C, 117: 0xF728, 119: 0xF72B, 121: 0xF72D,
            123: 0xF702, 124: 0xF703, 125: 0xF701, 126: 0xF700]
        if let value = values[keyCode], let scalar = UnicodeScalar(value) { return String(scalar) }
        let functionKeys: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        if let index = functionKeys.firstIndex(of: keyCode), let scalar = UnicodeScalar(0xF704 + index) {
            return String(scalar)
        }
        return keyName(keyCode)
    }

    private static let specialNames: [UInt16: String] = [
        36:"↩",48:"⇥",49:"Space",51:"⌫",53:"⎋",65:".",67:"*",69:"+",71:"⌧",75:"/",76:"⌤",78:"−",81:"=",
        82:"0",83:"1",84:"2",85:"3",86:"4",87:"5",88:"6",89:"7",91:"8",92:"9",
        114:"Help",115:"↖",116:"⇞",117:"⌦",119:"↘",121:"⇟",123:"←",124:"→",125:"↓",126:"↑",
        122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",
        103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"
    ]
}
