import AppKit
import Carbon.HIToolbox

struct GlobalShortcutRegistration: Hashable, Sendable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

enum ShortcutKeyPhase: Sendable { case pressed, released }

@MainActor
protocol GlobalShortcutRegistering: AnyObject {
    var onPress: ((GlobalShortcutRegistration) -> Void)? { get set }
    func register(_ shortcut: DeviceShortcut) throws -> GlobalShortcutRegistration
    /// Invalidates delivery even if the underlying unregistration fails.
    func unregister(_ registration: GlobalShortcutRegistration) throws
    func systemShortcuts() throws -> Set<DeviceShortcut>
    func retryFailedCleanup(for shortcut: DeviceShortcut?) throws
    func setDeliveryEnabled(_ enabled: Bool)
    func close() throws
}

/// Only this small boundary owns Carbon refs. Tests inject it without registering
/// any real global keys or installing an event handler in the hosted test app.
@MainActor
protocol ShortcutHotKeyRuntime: AnyObject {
    func installHandler(_ handler: @escaping (UInt32, ShortcutKeyPhase) -> Void,
                        onKeyRelease: @escaping (UInt16) -> Void) throws
    func register(_ shortcut: DeviceShortcut, eventID: UInt32) throws
    func unregister(eventID: UInt32) throws
    func systemShortcuts() throws -> Set<DeviceShortcut>
    func isKeyPressed(_ keyCode: UInt16) -> Bool
    func close() throws
}

@MainActor
final class GlobalShortcutService: GlobalShortcutRegistering {
    var onPress: ((GlobalShortcutRegistration) -> Void)?
    private enum KeyState { case ready, awaitingRecordingRelease, held }
    private struct Entry {
        let registration: GlobalShortcutRegistration
        let shortcut: DeviceShortcut
        var keyState: KeyState
    }
    private let runtime: any ShortcutHotKeyRuntime
    private var entries: [UInt32: Entry] = [:]
    private var lastEventID: UInt32 = 0
    private var handlerInstalled = false
    private var pendingCleanup: [UInt32: DeviceShortcut] = [:]
    private var deliveryEnabled = true
    private var closed = false
    private var recordingReleaseTask: Task<Void, Never>?

    init(runtime: any ShortcutHotKeyRuntime = CarbonShortcutRuntime()) {
        self.runtime = runtime
    }

    func register(_ shortcut: DeviceShortcut) throws -> GlobalShortcutRegistration {
        guard !closed else { throw ShortcutError.closed }
        try retryFailedCleanup(for: shortcut)
        guard !entries.values.contains(where: { $0.shortcut == shortcut }) else {
            throw ShortcutError.registration(operation: String(localized: "shortcut.register", defaultValue: "Register shortcut"), status: Int32(eventHotKeyExistsErr))
        }
        if !handlerInstalled {
            try runtime.installHandler({ [weak self] id, phase in self?.receive(id, phase: phase) },
                                       onKeyRelease: { [weak self] keyCode in self?.keyReleased(keyCode) })
            handlerInstalled = true
        }
        guard lastEventID < UInt32.max else {
            throw ShortcutError.unavailable(String(localized: "shortcut.event_ids_exhausted", defaultValue: "Shortcut event identifiers are exhausted. Restart the app."))
        }
        lastEventID += 1 // Never recycle IDs: Carbon events may already be queued.
        let eventID = lastEventID
        do { try runtime.register(shortcut, eventID: eventID) }
        catch {
            // A runtime may have acquired a reference before reporting failure.
            // It retains any reference that cannot be removed, for final close.
            do { try runtime.unregister(eventID: eventID) }
            catch { pendingCleanup[eventID] = shortcut }
            throw error
        }
        let registration = GlobalShortcutRegistration()
        // Recording commits while the accepted key is still physically down.
        // That same gesture must not immediately become an audio selection.
        entries[eventID] = Entry(registration: registration, shortcut: shortcut,
                                 keyState: runtime.isKeyPressed(shortcut.keyCode) ? .awaitingRecordingRelease : .ready)
        updateRecordingReleaseObservation()
        return registration
    }

    func unregister(_ registration: GlobalShortcutRegistration) throws {
        guard let id = entries.first(where: { $0.value.registration == registration })?.key,
              let entry = entries[id] else { return }
        entries[id] = nil // Invalidate before the system call, including failure.
        updateRecordingReleaseObservation()
        do { try runtime.unregister(eventID: id) }
        catch { pendingCleanup[id] = entry.shortcut; throw error }
    }

    func systemShortcuts() throws -> Set<DeviceShortcut> {
        guard !closed else { throw ShortcutError.closed }
        return try runtime.systemShortcuts()
    }

    func retryFailedCleanup(for shortcut: DeviceShortcut?) throws {
        guard !closed else { throw ShortcutError.closed }
        for (id, pendingShortcut) in pendingCleanup where shortcut == nil || shortcut == pendingShortcut {
            try runtime.unregister(eventID: id)
            pendingCleanup[id] = nil
        }
    }

    func setDeliveryEnabled(_ enabled: Bool) {
        guard !closed else { return }
        deliveryEnabled = enabled
        if enabled {
            // Sleep and nested loops can lose a release event. Preserve a held
            // gesture, but do not swallow the next press after a physical release.
            for (id, entry) in entries where entry.keyState != .ready && !runtime.isKeyPressed(entry.shortcut.keyCode) {
                entries[id]?.keyState = .ready
            }
            updateRecordingReleaseObservation()
        }
        // Keep held latches until release. Resuming cannot turn a held key into
        // a fresh press, even if a repeat arrives after a modal window closes.
    }

    func close() throws {
        closed = true
        deliveryEnabled = false
        recordingReleaseTask?.cancel()
        recordingReleaseTask = nil
        entries.removeAll()
        onPress = nil
        // Idempotent at the service boundary; failed native cleanup is retried.
        try runtime.close()
    }

    private func receive(_ id: UInt32, phase: ShortcutKeyPhase) {
        guard !closed, var entry = entries[id] else { return }
        switch phase {
        case .released:
            entry.keyState = .ready
            entries[id] = entry
            updateRecordingReleaseObservation()
        case .pressed:
            guard entry.keyState == .ready else { return }
            entry.keyState = .held
            entries[id] = entry
            guard deliveryEnabled else { return }
            onPress?(entry.registration)
        }
    }

    private func keyReleased(_ keyCode: UInt16) {
        guard !closed else { return }
        for (id, entry) in entries where entry.shortcut.keyCode == keyCode {
            entries[id]?.keyState = .ready
        }
        updateRecordingReleaseObservation()
    }

    private func updateRecordingReleaseObservation() {
        guard !closed, entries.values.contains(where: { $0.keyState == .awaitingRecordingRelease }) else {
            recordingReleaseTask?.cancel()
            recordingReleaseTask = nil
            return
        }
        guard recordingReleaseTask == nil else { return }
        // Registration happens during the recorder's keyDown. Carbon need not
        // pair that pre-registration gesture with a hot-key release. Raw keyUp
        // is the immediate path; physical checks also cover losing app focus
        // before releasing. Observe only these initial holds, never clear one
        // merely because a delay elapsed or a new hot-key press arrived.
        recordingReleaseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { return }
                guard !Task.isCancelled, let self, !self.closed else { return }
                for (id, entry) in self.entries where entry.keyState == .awaitingRecordingRelease {
                    if !self.runtime.isKeyPressed(entry.shortcut.keyCode) {
                        self.entries[id]?.keyState = .ready
                    }
                }
                self.updateRecordingReleaseObservation()
            }
        }
    }

    isolated deinit { recordingReleaseTask?.cancel() }
}

extension ShortcutModifiers {
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    init(carbonFlags: UInt32) {
        var modifiers: Self = []
        if carbonFlags & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        if carbonFlags & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if carbonFlags & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if carbonFlags & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        self = modifiers
    }
}

@MainActor
private final class CarbonShortcutCallbackBox {
    var handler: ((UInt32, ShortcutKeyPhase) -> Void)?
    var onKeyRelease: ((UInt16) -> Void)?
    init(handler: @escaping (UInt32, ShortcutKeyPhase) -> Void,
         onKeyRelease: @escaping (UInt16) -> Void) {
        self.handler = handler
        self.onKeyRelease = onKeyRelease
    }
}

private let toneHopHotKeySignature: OSType = 0x54484B34 // THK4

/// Carbon dispatches the application event handler on the main thread. Refuse
/// unexpected delivery rather than exporting event refs across actor boundaries.
nonisolated private func toneHopHotKeyCallback(
    _: EventHandlerCallRef?, event: EventRef?, context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard Thread.isMainThread, let event, let context,
          GetEventClass(event) == OSType(kEventClassKeyboard) else { return OSStatus(eventNotHandledErr) }
    let kind = GetEventKind(event)
    let box = Unmanaged<CarbonShortcutCallbackBox>.fromOpaque(context).takeUnretainedValue()
    if kind == UInt32(kEventRawKeyUp) {
        var keyCode: UInt32 = 0
        var actualSize = 0
        let status = GetEventParameter(event, UInt32(kEventParamKeyCode), UInt32(typeUInt32),
                                       nil, MemoryLayout<UInt32>.size, &actualSize, &keyCode)
        if status == noErr, actualSize == MemoryLayout<UInt32>.size, let keyCode = UInt16(exactly: keyCode) {
            MainActor.assumeIsolated { box.onKeyRelease?(keyCode) }
        }
        // Observe the recording gesture's release without consuming AppKit input.
        return OSStatus(eventNotHandledErr)
    }
    guard kind == UInt32(kEventHotKeyPressed) || kind == UInt32(kEventHotKeyReleased) else {
        return OSStatus(eventNotHandledErr)
    }
    var hotKey = EventHotKeyID()
    var actualSize = 0
    let result = GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, &actualSize, &hotKey)
    guard result == noErr, actualSize == MemoryLayout<EventHotKeyID>.size,
          hotKey.signature == toneHopHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let eventID = hotKey.id
    let phase: ShortcutKeyPhase = kind == UInt32(kEventHotKeyPressed) ? .pressed : .released
    return MainActor.assumeIsolated {
        guard let handler = box.handler else { return OSStatus(eventNotHandledErr) }
        handler(eventID, phase)
        return noErr
    }
}

/// Native calls are a narrow injectable boundary: error + nonnull out-ref and
/// failed removal can be exercised without installing a real event handler.
@MainActor
protocol CarbonShortcutCalling {
    func install(handler: EventHandlerUPP, context: UnsafeMutableRawPointer) -> (OSStatus, EventHandlerRef?)
    func remove(_ handler: EventHandlerRef) -> OSStatus
    func register(_ shortcut: DeviceShortcut, eventID: UInt32) -> (OSStatus, EventHotKeyRef?)
    func unregister(_ reference: EventHotKeyRef) -> OSStatus
    func isKeyPressed(_ keyCode: UInt16) -> Bool
}

@MainActor
struct SystemCarbonShortcutCalls: CarbonShortcutCalling {
    func install(handler: EventHandlerUPP, context: UnsafeMutableRawPointer) -> (OSStatus, EventHandlerRef?) {
        var installed: EventHandlerRef?
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventRawKeyUp))
        ]
        let status = InstallEventHandler(GetEventDispatcherTarget(), handler,
                                         events.count, &events, context, &installed)
        return (status, installed)
    }

    func remove(_ handler: EventHandlerRef) -> OSStatus { RemoveEventHandler(handler) }

    func register(_ shortcut: DeviceShortcut, eventID: UInt32) -> (OSStatus, EventHotKeyRef?) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers.carbonFlags,
                                          EventHotKeyID(signature: toneHopHotKeySignature, id: eventID),
                                          GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        return (status, reference)
    }

    func unregister(_ reference: EventHotKeyRef) -> OSStatus { UnregisterEventHotKey(reference) }
    func isKeyPressed(_ keyCode: UInt16) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }
}

@MainActor
final class CarbonShortcutRuntime: ShortcutHotKeyRuntime {
    private let calls: any CarbonShortcutCalling
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var callbackContext: UnsafeMutableRawPointer?
    private var closed = false

    init(calls: any CarbonShortcutCalling = SystemCarbonShortcutCalls()) { self.calls = calls }

    func installHandler(_ handler: @escaping (UInt32, ShortcutKeyPhase) -> Void,
                        onKeyRelease: @escaping (UInt16) -> Void) throws {
        guard !closed else { throw ShortcutError.closed }
        if eventHandler != nil {
            guard let callbackContext,
                  Unmanaged<CarbonShortcutCallbackBox>.fromOpaque(callbackContext).takeUnretainedValue().handler != nil else {
                throw ShortcutError.unavailable(String(localized: "shortcut.listener_unavailable", defaultValue: "The shortcut listener is unavailable. Restart the app."))
            }
            return
        }
        let box = CarbonShortcutCallbackBox(handler: handler, onKeyRelease: onKeyRelease)
        let context = Unmanaged.passRetained(box).toOpaque()
        let (status, installed) = calls.install(handler: toneHopHotKeyCallback, context: context)
        if let installed {
            eventHandler = installed
            callbackContext = context
        } else {
            Unmanaged<CarbonShortcutCallbackBox>.fromOpaque(context).release()
        }
        guard status == noErr, installed != nil else {
            box.handler = nil
            box.onKeyRelease = nil
            if let installed {
                // Remove invalidates the ref even on error. Never retry that ref.
                eventHandler = nil
                callbackContext = nil
                if calls.remove(installed) == noErr {
                    Unmanaged<CarbonShortcutCallbackBox>.fromOpaque(context).release()
                } else {
                    // With uncertain removal, keep a nil callback box alive and
                    // stop accepting work rather than installing another handler.
                    closed = true
                }
            }
            throw ShortcutError.registration(operation: String(localized: "shortcut.install_listener", defaultValue: "Install shortcut listener"), status: status == noErr ? -1 : status)
        }
    }

    func register(_ shortcut: DeviceShortcut, eventID: UInt32) throws {
        guard !closed else { throw ShortcutError.closed }
        guard eventHandler != nil else {
            throw ShortcutError.unavailable(String(localized: "shortcut.listener_not_ready", defaultValue: "The shortcut listener is not ready yet."))
        }
        let (status, reference) = calls.register(shortcut, eventID: eventID)
        if let reference { references[eventID] = reference }
        guard status == noErr, reference != nil else {
            throw ShortcutError.registration(operation: String(localized: "shortcut.register", defaultValue: "Register shortcut"), status: status == noErr ? -1 : status)
        }
    }

    func unregister(eventID: UInt32) throws {
        guard let reference = references[eventID] else { return }
        let status = calls.unregister(reference)
        guard status == noErr else {
            throw ShortcutError.registration(operation: String(localized: "shortcut.release", defaultValue: "Release shortcut"), status: status)
        }
        references[eventID] = nil
    }

    func isKeyPressed(_ keyCode: UInt16) -> Bool {
        calls.isKeyPressed(keyCode)
    }

    func systemShortcuts() throws -> Set<DeviceShortcut> {
        guard !closed else { throw ShortcutError.closed }
        var result: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&result)
        let array = result?.takeRetainedValue()
        guard status == noErr, let rows = array as? [[String: Any]] else {
            throw ShortcutError.registration(operation: String(localized: "shortcut.check_system", defaultValue: "Check system shortcuts"), status: status == noErr ? -1 : status)
        }
        var shortcuts = Set<DeviceShortcut>()
        for row in rows {
            guard let enabled = row[kHISymbolicHotKeyEnabled] as? NSNumber,
                  CFGetTypeID(enabled) == CFBooleanGetTypeID() else {
                throw ShortcutError.unavailable(String(localized: "shortcut.system_check_incomplete", defaultValue: "System shortcuts could not be fully checked. Try again later."))
            }
            guard enabled.boolValue else { continue }
            guard let code = row[kHISymbolicHotKeyCode] as? NSNumber,
                  let flags = row[kHISymbolicHotKeyModifiers] as? NSNumber,
                  let keyCode = UInt16(exactly: code.int64Value),
                  let modifiers = UInt32(exactly: flags.int64Value) else {
                throw ShortcutError.unavailable(String(localized: "shortcut.system_check_incomplete", defaultValue: "System shortcuts could not be fully checked. Try again later."))
            }
            // Ignore combinations the product cannot record. Carbon may include
            // a synthesized Fn flag for navigation/function keys.
            if let shortcut = try? DeviceShortcut(keyCode: keyCode, modifiers: .init(carbonFlags: modifiers)) {
                shortcuts.insert(shortcut)
            }
        }
        return shortcuts
    }

    func close() throws {
        closed = true
        if let callbackContext {
            let box = Unmanaged<CarbonShortcutCallbackBox>.fromOpaque(callbackContext).takeUnretainedValue()
            box.handler = nil
            box.onKeyRelease = nil
        }
        var firstError: (any Error)?
        for id in Array(references.keys) {
            do { try unregister(eventID: id) }
            catch { if firstError == nil { firstError = error } }
        }
        if let eventHandler {
            self.eventHandler = nil // SDK: the ref is invalid after this call.
            let status = calls.remove(eventHandler)
            if status == noErr {
                if let callbackContext {
                    Unmanaged<CarbonShortcutCallbackBox>.fromOpaque(callbackContext).release()
                    self.callbackContext = nil
                }
            } else if firstError == nil {
                firstError = ShortcutError.registration(operation: String(localized: "shortcut.close_listener", defaultValue: "Close shortcut listener"), status: status)
            }
            // Failed removal retains an inert callback box for process lifetime.
            // It is deliberately not retried with an invalid EventHandlerRef.
            self.callbackContext = nil
        }
        if let firstError { throw firstError }
    }

    isolated deinit {
        // If RemoveEventHandler fails, the retained box intentionally outlives
        // this object with a nil handler; queued C callbacks never dereference a
        // released owner. The system reclaims process registrations at exit.
        try? close()
    }
}
