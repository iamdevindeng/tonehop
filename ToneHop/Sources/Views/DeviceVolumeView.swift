import SwiftUI

struct DeviceVolumeView: View {
    let device: AudioDevice
    let store: AudioVolumeStore

    private var state: AudioVolumeRowState? { store.state(for: device.id) }
    private var issue: AudioVolumeIssue? { state?.issue ?? state?.snapshot?.capability.issue }
    private var reason: String? {
        if issue == .unsupported { return String(localized: "ui.volume.unsupported", defaultValue: "Volume control unavailable") }
        if issue == .notConnected { return String(localized: "ui.volume.connect", defaultValue: "Connect to view volume") }
        if case .writeFailed = issue { return String(localized: "ui.volume.failed", defaultValue: "Volume change failed. Try again.") }
        if issue == .unconfirmed { return String(localized: "ui.volume.unconfirmed", defaultValue: "Volume not yet confirmed") }
        if let issue { return issue.localizedDescription }
        if state?.isMuted == true { return String(localized: "ui.volume.muted", defaultValue: "Muted; raise volume to try unmuting") }
        return nil
    }
    private var showsTrack: Bool { Self.showsTrack(state: state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsTrack {
                HStack(spacing: 8) {
                    NativeVolumeSlider(
                        value: Double(state?.value ?? 0),
                        isEnabled: state?.canWrite == true && !store.isPaused && !store.isClosed,
                        label: String(localized: "ui.volume.label", defaultValue: "System volume for \(device.name)"),
                        valueDescription: state?.percent.map { "\($0)%" } ?? String(localized: "ui.volume.unavailable", defaultValue: "Unavailable"),
                        hint: issue?.localizedDescription ?? reason ?? String(localized: "ui.volume.help", defaultValue: "Adjust this device’s volume without switching sound output"),
                        onValueChange: { store.setVolume(Float($0), for: device.id) },
                        onEditingChanged: { editing in
                            if editing { store.beginEditing(device.id) }
                            else { store.endEditing(device.id) }
                        }
                    )
                    .frame(height: 24)

                    Text(state?.percent.map { "\($0)%" } ?? "-")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .frame(width: 37, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                .frame(height: 24)

                if let reason { hint(reason) }
            } else {
                HStack(spacing: 8) {
                    hint(reason ?? (state?.isReading == true ? String(localized: "ui.volume.reading", defaultValue: "Reading volume…") : String(localized: "ui.volume.unconfirmed", defaultValue: "Volume not yet confirmed")))
                    Spacer(minLength: 0)
                    Text("-")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 37, alignment: .trailing)
                        .accessibilityLabel(issue == .unsupported ? String(localized: "ui.volume.unsupported", defaultValue: "Volume control unavailable") : String(localized: "ui.volume.value_unconfirmed", defaultValue: "Volume value not yet confirmed"))
                }
                .frame(height: 24, alignment: .leading)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if Self.isFailure(issue) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            Text(text)
                .foregroundStyle(Self.isFailure(issue) ? .primary : .secondary)
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .frame(height: DeviceRowView.issueHeight, alignment: .leading)
        .help(issue?.localizedDescription ?? text)
    }

    /// An absent value is not a zero-volume result. Unsupported targets have
    /// explanatory text and a placeholder; confirmed zero retains its track and percentage.
    static func showsTrack(state: AudioVolumeRowState?) -> Bool {
        guard let state, state.value != nil,
              state.snapshot?.capability.issue != .unsupported else { return false }
        return true
    }

    static func hasHint(deviceID: String, store: AudioVolumeStore?) -> Bool {
        guard let state = store?.state(for: deviceID), showsTrack(state: state) else { return false }
        return state.issue != nil || state.isMuted
    }

    private static func isFailure(_ issue: AudioVolumeIssue?) -> Bool {
        switch issue {
        case .invalidValue, .invalidReadback, .readFailed, .writeFailed, .unconfirmed,
             .mutedVolumeUnconfirmed, .unmutedVolumeUnconfirmed, .stillMuted, .muteUnknown:
            true
        default: false
        }
    }
}
