import SwiftUI

/// Uses the same evidence-backed symbol as the menu bar. Selection changes only
/// the badge; it never resolves a model from a name or transport category.
struct AudioDeviceIconView: View {
    let device: AudioDevice
    let isCurrent: Bool

    var body: some View {
        Image(systemName: DeviceIconRendering.symbolName(for: device.icon))
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(isCurrent ? Color(nsColor: .systemBlue) : .primary)
            .frame(width: 36, height: 36)
            .background {
                if isCurrent {
                    Circle().fill(.white)
                } else {
                    Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.75)
                }
            }
            .accessibilityHidden(true)
    }
}
