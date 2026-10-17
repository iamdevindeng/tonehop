import AppKit

/// Symbol availability is a UI concern, never audio capability evidence.
@MainActor
enum DeviceIconRendering {
    static func symbolName(for icon: AudioDeviceIcon) -> String {
        NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil) == nil
            ? AudioDeviceIcon.fallback.symbolName : icon.symbolName
    }
}
