import Foundation

/// The persisted representation is independent of AppKit/Carbon flag layouts.
struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    let rawValue: UInt8
    static let command = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
    static let supported: Self = [.command, .control, .option, .shift]

    var symbols: String {
        [(Self.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .compactMap { contains($0.0) ? $0.1 : nil }.joined()
    }
}

struct DeviceShortcut: Hashable, Codable, Sendable {
    let keyCode: UInt16
    let modifiers: ShortcutModifiers

    init(keyCode: UInt16, modifiers: ShortcutModifiers) throws {
        guard modifiers.subtracting(.supported).isEmpty else { throw ShortcutError.unsupportedModifiers }
        guard !modifiers.intersection([.command, .control]).isEmpty else {
            throw ShortcutError.requiresCommandOrControl
        }
        guard Self.supportedKeyCodes.contains(keyCode) else { throw ShortcutError.unsupportedKey }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(keyCode: values.decode(UInt16.self, forKey: .keyCode),
                      modifiers: values.decode(ShortcutModifiers.self, forKey: .modifiers))
    }

    /// Public HIToolbox virtual keys: text, keypad, navigation and F1–F20.
    /// Modifier/media/unassigned codes cannot become bindings, including on import.
    static let supportedKeyCodes: Set<UInt16> = Set(UInt16(0)...UInt16(51)).union([
        53, 64, 65, 67, 69, 71, 75, 76, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87,
        88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104,
        105, 106, 107, 109, 111, 113, 114, 115, 116, 117, 118, 119, 120, 121,
        122, 123, 124, 125, 126
    ])

    static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113,
        106, 64, 79, 80, 90
    ]

    /// AppKit synthesizes Fn on these keys even when Fn was not pressed.
    static let keysWithSynthesizedFunctionFlag: Set<UInt16> = functionKeyCodes.union([
        114, 115, 116, 117, 119, 121, 123, 124, 125, 126
    ])
}

enum ShortcutError: Error, LocalizedError, Equatable, Sendable {
    case requiresCommandOrControl
    case unsupportedModifiers
    case unsupportedKey
    case duplicateBinding(String)
    case systemConflict
    case menuConflict(String)
    case registration(operation: String, status: Int32)
    case invalidConfiguration
    case unsupportedVersion(Int)
    case unavailable(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .requiresCommandOrControl: String(localized: "shortcut.modifier_required", defaultValue: "Include ⌘ Command or ⌃ Control in the shortcut.")
        case .unsupportedModifiers: String(localized: "shortcut.unsupported_modifier", defaultValue: "This modifier is not supported. Use Command, Control, Option, or Shift.")
        case .unsupportedKey: String(localized: "shortcut.unsupported_key", defaultValue: "This key is not supported. Choose a regular key or an F key.")
        case let .duplicateBinding(name): String(localized: "shortcut.duplicate_binding", defaultValue: "This shortcut is already assigned to “\(name)”.")
        case .systemConflict: String(localized: "shortcut.system_conflict", defaultValue: "macOS uses this shortcut. Choose another combination.")
        case let .menuConflict(name): String(localized: "shortcut.menu_conflict", defaultValue: "This shortcut is already assigned to the “\(name)” menu item.")
        case let .registration(operation, status):
            status == -9878 ? String(localized: "shortcut.already_taken", defaultValue: "This shortcut is already in use. Choose another combination.") : String(localized: "shortcut.registration_failed", defaultValue: "\(operation) failed (\(Int(status))). Try again.")
        case .invalidConfiguration: String(localized: "shortcut.invalid_configuration", defaultValue: "The shortcut configuration could not be read. The original file has been kept.")
        case let .unsupportedVersion(version): String(localized: "shortcut.unsupported_version", defaultValue: "Shortcut configuration version \(version) is not supported. The original file has been kept.")
        case let .unavailable(message): message
        case .closed: String(localized: "shortcut.closed", defaultValue: "The shortcut service is closed.")
        }
    }
}
