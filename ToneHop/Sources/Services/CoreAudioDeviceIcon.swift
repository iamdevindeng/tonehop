import CoreAudio
import Darwin
import Foundation
import IOKit.audio

/// Pure graphic projection from model/terminal evidence. A stable HDMI or
/// DisplayPort connection can supply a generic display glyph when the terminal
/// is unspecified; it never identifies a particular display model.
enum CoreAudioDeviceIcon {
    static func resolve(modelIdentifier: String?, modelSymbol: String?,
                        verifiedBuiltInSpeaker: Bool, hostModelIdentifier: String?, hostModelSymbol: String?,
                        terminalTypes: [UInt32], imageFileURL: URL?,
                        confirmedTransportType: UInt32? = nil) -> AudioDeviceIcon {
        if let modelSymbol, !modelSymbol.isEmpty {
            return .systemSymbol(modelSymbol, modelIdentifier: modelIdentifier, imageFileURL: imageFileURL)
        }
        if verifiedBuiltInSpeaker, let hostModelSymbol, !hostModelSymbol.isEmpty {
            return .systemSymbol(hostModelSymbol, modelIdentifier: hostModelIdentifier, imageFileURL: imageFileURL)
        }
        let headphones: Set<UInt32> = [kAudioStreamTerminalTypeHeadphones, UInt32(OUTPUT_HEADPHONES)]
        let displays: Set<UInt32> = [kAudioStreamTerminalTypeHDMI, kAudioStreamTerminalTypeDisplayPort,
                                   UInt32(OUTPUT_HEAD_MOUNTED_DISPLAY_AUDIO)]
        let speakers: Set<UInt32> = [kAudioStreamTerminalTypeSpeaker, UInt32(OUTPUT_SPEAKER),
                                   kAudioStreamTerminalTypeLFESpeaker, UInt32(OUTPUT_LOW_FREQUENCY_EFFECTS_SPEAKER)]
        let symbol: String?
        if !terminalTypes.isEmpty, terminalTypes.allSatisfy(headphones.contains) { symbol = "headphones" }
        else if !terminalTypes.isEmpty, terminalTypes.allSatisfy(displays.contains) { symbol = "display" }
        else if !terminalTypes.isEmpty, terminalTypes.allSatisfy(speakers.contains) { symbol = "speaker.wave.2.fill" }
        else { symbol = nil }
        guard let symbol else {
            // Some display audio drivers (including the sampled HDMI output)
            // leave their stream terminal unknown. This narrow connection
            // graphic must not override known or conflicting terminal evidence,
            // nor guess headphones/speakers from Bluetooth or USB transport.
            if terminalTypes.allSatisfy({ $0 == kAudioStreamTerminalTypeUnknown }),
               confirmedTransportType == kAudioDeviceTransportTypeHDMI ||
               confirmedTransportType == kAudioDeviceTransportTypeDisplayPort {
                return AudioDeviceIcon(symbolName: "display", source: .displayConnection,
                                       modelIdentifier: modelIdentifier, imageFileURL: imageFileURL)
            }
            return .systemSymbol(nil, modelIdentifier: modelIdentifier, imageFileURL: imageFileURL)
        }
        return AudioDeviceIcon(symbolName: symbol, source: .outputTerminal,
                               modelIdentifier: modelIdentifier, imageFileURL: imageFileURL)
    }

    static func currentHostModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size < 1024 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0,
              let terminator = bytes.firstIndex(of: 0), terminator > 0 else { return nil }
        return String(bytes: bytes.prefix(terminator).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}
