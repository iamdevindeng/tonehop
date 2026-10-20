import Foundation

/// Projects confirmed volume evidence without reading hardware or changing output.
struct StatusBarVolumePresentation: Equatable {
    enum Content: Equatable {
        case percentage(Int)
        case muted
        case unavailable
    }

    let content: Content
    let help: String

    init(device: AudioDevice?, state: AudioVolumeRowState?, isPaused: Bool, isClosed: Bool) {
        guard !isClosed else {
            self.init(content: .unavailable, help: AudioVolumeIssue.closed.localizedDescription)
            return
        }
        guard let device else {
            self.init(content: .unavailable, help: String(localized: "ui.status.volume.current_unconfirmed",
                defaultValue: "Volume unavailable until the current output is confirmed"))
            return
        }
        guard !isPaused else {
            self.init(content: .unavailable, help: String(localized: "ui.status.volume.confirming",
                defaultValue: "Confirming volume…"))
            return
        }
        guard let state else {
            self.init(content: .unavailable, help: Self.readingHelp)
            return
        }
        guard state.deviceID == device.id, !device.id.isEmpty else {
            self.init(content: .unavailable, help: Self.identityHelp)
            return
        }
        guard let target = state.target else {
            self.init(content: .unavailable, help: Self.unavailableHelp(issue: state.issue, isReading: state.isReading))
            return
        }
        guard target.deviceID == device.id, !target.uid.isEmpty,
              Self.matchesDevice(target, device: device) else {
            self.init(content: .unavailable, help: Self.identityHelp)
            return
        }
        guard let snapshot = state.snapshot else {
            self.init(content: .unavailable, help: Self.unavailableHelp(issue: state.issue, isReading: state.isReading))
            return
        }
        guard snapshot.target == target else {
            self.init(content: .unavailable, help: Self.identityHelp)
            return
        }
        if let value = snapshot.value, !AudioVolumeScalar.validScalar(value) {
            self.init(content: .unavailable, help: AudioVolumeIssue.invalidReadback.localizedDescription)
            return
        }

        // The row's draft is an intended slider value, never a system readback.
        let percent = snapshot.value.map { Int(($0 * 100).rounded()) }
        let content: Content
        var details: [String]
        if snapshot.mute == .muted {
            content = .muted
            details = [percent.map {
                String(localized: "ui.status.volume.muted_value", defaultValue: "Muted; volume setting \($0)%")
            } ?? String(localized: "ui.status.volume.muted_unavailable", defaultValue: "Muted; volume unavailable")]
        } else {
            content = percent.map(Content.percentage) ?? .unavailable
            details = [percent.map {
                String(localized: "ui.status.volume.value", defaultValue: "Volume \($0)%")
            } ?? Self.unavailableHelp(issue: snapshot.capability.issue, isReading: state.isReading)]
            switch snapshot.mute {
            case .mixed:
                details.append(String(localized: "ui.status.volume.mixed_mute", defaultValue: "Some channels are muted"))
            case .unknown:
                details.append(String(localized: "ui.status.volume.mute_unknown", defaultValue: "Mute status is unconfirmed"))
            case .unsupported:
                details.append(String(localized: "ui.status.volume.mute_unavailable", defaultValue: "Mute status is unavailable"))
            case .unmuted, .muted:
                break
            }
        }
        // Readability and writability are independent. A control limitation
        // explains a readable value without suppressing it.
        if let issue = snapshot.capability.issue, percent != nil {
            details.append(issue.localizedDescription)
        }
        self.init(content: content, help: details.joined(separator: "\n"))
    }

    private init(content: Content, help: String) {
        self.content = content
        self.help = help
    }

    private static var readingHelp: String {
        String(localized: "ui.volume.reading", defaultValue: "Reading volume…")
    }

    private static var identityHelp: String {
        String(localized: "ui.status.volume.identity_unconfirmed",
               defaultValue: "Volume unavailable until the device is confirmed")
    }

    private static func matchesDevice(_ target: AudioVolumeTarget, device: AudioDevice) -> Bool {
        switch device.backend {
        case let .coreAudio(uid):
            target.uid == uid && target.receiverID == nil
        case let .privateRoute(identifier):
            !identifier.isEmpty && target.receiverID == identifier
        case .unavailable:
            false
        }
    }

    private static func unavailableHelp(issue: AudioVolumeIssue?, isReading: Bool) -> String {
        switch issue {
        case .unsupported:
            String(localized: "ui.status.volume.unsupported",
                   defaultValue: "This device does not provide a system volume value")
        case .identityUnconfirmed, .identityChanged:
            identityHelp
        case .invalidReadback, .readFailed, .notConnected, .closed:
            issue?.localizedDescription ?? identityHelp
        case .paused:
            String(localized: "ui.status.volume.confirming", defaultValue: "Confirming volume…")
        default:
            isReading ? readingHelp : String(localized: "ui.status.volume.unavailable", defaultValue: "Volume unavailable")
        }
    }
}
