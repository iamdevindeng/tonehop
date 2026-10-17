import SwiftUI

struct AudioFeedbackView: View {
    let store: AudioStore
    var shortcuts: ShortcutStore? = nil

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                feedbackSymbol
                    .accessibilityHidden(true)

                Text(store.presentationFeedback)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .help(store.feedback)
            .accessibilityElement(children: .combine)

            if let warning = Self.visibleCatalogWarning(store.catalogWarning, devices: store.devices,
                                                       currentDeviceID: store.currentDeviceID) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let message = shortcuts?.footerMessage, message != store.feedback {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let shortcuts, let title = shortcuts.recoveryTitle {
                Button(title) { shortcuts.retryRecovery() }
                    .controlSize(.small)
                    .disabled(!shortcuts.canRecover)
                    .accessibilityLabel(String(localized: "ui.shortcut.recovery_label", defaultValue: "\(title) shortcuts"))
            }
        }
    }

    /// Device-specific guidance belongs beside the unavailable device. Keep the
    /// original catalog warning in the store for diagnostics and filter only
    /// complete hint blocks that the rows already present.
    static func visibleCatalogWarning(_ warning: String?, devices: [AudioDevice], currentDeviceID: String?) -> String? {
        guard let warning else { return nil }
        let hintBlocks = Set(devices.compactMap {
            DeviceRowView.unavailableHint(for: $0, isCurrent: $0.id == currentDeviceID)
        }).map { $0.components(separatedBy: "\n") }.sorted { $0.count > $1.count }
        guard !hintBlocks.isEmpty else { return warning }

        let lines = warning.components(separatedBy: "\n")
        var remaining: [String] = []
        var index = 0
        while index < lines.count {
            if let hint = hintBlocks.first(where: { lines[index...].starts(with: $0) }) {
                index += hint.count
            } else {
                remaining.append(lines[index])
                index += 1
            }
        }
        guard remaining.contains(where: { !$0.isEmpty }) else { return nil }
        return remaining.joined(separator: "\n")
    }

    @ViewBuilder
    private var feedbackSymbol: some View {
        switch store.feedbackKind {
        case .neutral, .success:
            EmptyView()
        case .progress:
            ProgressView()
                .controlSize(.small)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
        }
    }
}
