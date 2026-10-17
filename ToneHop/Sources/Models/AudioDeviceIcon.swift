import Foundation

/// Presentation evidence only. A device graphic never grants identity,
/// discovery, switching, volume, or selected-output capability.
struct AudioDeviceIcon: Equatable, Codable, Sendable {
    enum Source: String, Codable, Sendable {
        case fallback, systemSymbol, outputTerminal, displayConnection
    }

    let symbolName: String
    let source: Source
    var modelIdentifier: String? = nil
    /// HAL's public image URL may be a coloured driver/application icon. Keep
    /// it as evidence; do not turn it into a guessed monochrome device shape.
    var imageFileURL: URL? = nil

    static let fallback = AudioDeviceIcon(symbolName: "speaker.wave.2.fill", source: .fallback)

    static func systemSymbol(_ symbol: String?, modelIdentifier: String? = nil,
                             imageFileURL: URL? = nil) -> Self {
        let name = symbol?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else {
            var fallback = Self.fallback
            fallback.modelIdentifier = modelIdentifier
            fallback.imageFileURL = imageFileURL
            return fallback
        }
        return Self(symbolName: name, source: .systemSymbol,
                    modelIdentifier: modelIdentifier, imageFileURL: imageFileURL)
    }
}
