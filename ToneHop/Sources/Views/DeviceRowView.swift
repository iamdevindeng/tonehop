import SwiftUI

/// Output, shortcut and volume controls have independent hit regions.
struct DeviceRowView: View {
    static let baseHeight: CGFloat = 65
    static let unavailableHintSpacing: CGFloat = 3
    static let issueHeight: CGFloat = 18
    static let shortcutWidth: CGFloat = 70

    let device: AudioDevice
    let isCurrent: Bool
    let isSwitching: Bool
    let select: () -> Void
    var interactions: AudioInteractionCoordinator? = nil

    private var shortcutIssue: String? {
        guard let target = device.shortcutTarget else { return nil }
        return interactions?.shortcuts.rowIssue(for: target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.unavailableHintSpacing) {
            HStack(alignment: .center, spacing: 12) {
                AudioDeviceIconView(device: device, isCurrent: isCurrent)
                    .overlay {
                        Button(action: select) { Color.clear.contentShape(Circle()) }
                            .buttonStyle(.plain)
                            .disabled(isSwitching || !device.isAvailable)
                            .accessibilityHidden(true)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    controls

                    if let volume = interactions?.volume {
                        DeviceVolumeView(device: device, store: volume)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let reason = Self.unavailableHint(for: device, isCurrent: isCurrent) {
                Text(Self.unavailableHintText(for: reason))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(height: Self.unavailableHintHeight(for: reason), alignment: .topLeading)
                    .padding(.leading, 48)
                    .help(reason)
            }

            if let shortcutIssue {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(shortcutIssue)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .frame(height: Self.issueHeight, alignment: .leading)
                .padding(.leading, 48)
                .help(shortcutIssue)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    static func unavailableHint(for device: AudioDevice, isCurrent: Bool) -> String? {
        guard device.transport == .airplay, !device.isAvailable, !isCurrent,
              let reason = device.unavailableReason, !reason.isEmpty else { return nil }
        return reason
    }

    // Keep the original reason for catalog-warning deduplication and help.
    // Only the familiar preparation guidance gets a shorter visible summary.
    static func unavailableHintText(for reason: String) -> String {
        reason == RetainedRouteCapability.preparationHint
            ? String(localized: "ui.device.prepare_short", defaultValue: "Select once in system Sound settings") : reason
    }

    static func unavailableHintHeight(for reason: String) -> CGFloat {
        reason == RetainedRouteCapability.preparationHint ? issueHeight : 60
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 0) {
                    Text(device.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 3)
                }
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSwitching || !device.isAvailable)
            .help(device.unavailableReason.map { "\(device.name)\n\($0)" } ?? device.name)
            .accessibilityLabel(device.name)
            .accessibilityValue(isCurrent ? String(localized: "ui.device.current", defaultValue: "Current sound output") : device.unavailableReason ?? "")
            .accessibilityHint(device.isAvailable ? String(localized: "ui.device.switch_hint", defaultValue: "Switch sound output to this device") : String(localized: "ui.device.unavailable", defaultValue: "Device is currently unavailable"))
            .accessibilityAddTraits(isCurrent ? .isSelected : [])

            if let interactions, let target = device.shortcutTarget {
                ShortcutRecorderView(store: interactions.shortcuts, target: target, deviceName: device.name)
                    .frame(width: Self.shortcutWidth, height: 26)
            } else {
                Text(String(localized: "ui.device.pending", defaultValue: "Pending"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.shortcutWidth, height: 26)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    }
                    .accessibilityLabel(String(localized: "ui.shortcut.pending_label", defaultValue: "Shortcut for \(device.name), device identity not yet confirmed"))
            }
        }
    }
}
