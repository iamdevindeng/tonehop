import Foundation

/// The catalog owns the receiver/stream association. A request never resolves a
/// display name or changes the default output to obtain a volume control.
struct AudioVolumeTarget: Hashable, Sendable {
    let deviceID: String
    let uid: String
    let receiverID: String?
    let generation: UUID
    let serviceGeneration: UUID?

    init(deviceID: String, uid: String, receiverID: String? = nil, generation: UUID = UUID(), serviceGeneration: UUID? = nil) {
        self.deviceID = deviceID
        self.uid = uid
        self.receiverID = receiverID
        self.generation = generation
        self.serviceGeneration = serviceGeneration
    }
}

enum AudioVolumeIssue: Error, Equatable, Sendable, LocalizedError {
    case unsupported
    case notConnected
    case identityUnconfirmed
    case identityChanged
    case readOnly
    case implementationGap
    case invalidValue
    case invalidReadback
    case readFailed(Int32)
    case writeFailed(Int32)
    case unconfirmed
    case mutedVolumeUnconfirmed
    case unmutedVolumeUnconfirmed
    case stillMuted
    case muteUnknown
    case paused
    case closed
    case listenerUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "volume.unsupported", defaultValue: "This device does not support system volume control")
        case .notConnected: String(localized: "volume.not_connected", defaultValue: "Connect to check whether volume control is supported")
        case .identityUnconfirmed: String(localized: "volume.identity_unconfirmed", defaultValue: "The device cannot be confirmed right now")
        case .identityChanged: String(localized: "volume.identity_changed", defaultValue: "The device state changed. Try adjusting the volume again")
        case .readOnly: String(localized: "volume.read_only", defaultValue: "The volume of this device cannot be adjusted here")
        case .implementationGap: String(localized: "volume.compatibility_unverified", defaultValue: "Volume control compatibility has not yet been verified for this device")
        case .invalidValue: String(localized: "volume.invalid_value", defaultValue: "Invalid volume value")
        case .invalidReadback: String(localized: "volume.invalid_readback", defaultValue: "The system returned an invalid volume value")
        case let .readFailed(status): String(localized: "volume.read_failed", defaultValue: "Cannot read the volume right now (\(Int(status)))")
        case let .writeFailed(status): String(localized: "volume.write_failed", defaultValue: "Volume adjustment failed (\(Int(status)))")
        case .unconfirmed: String(localized: "volume.unconfirmed", defaultValue: "The system has not yet confirmed the volume change")
        case .mutedVolumeUnconfirmed: String(localized: "volume.muted_unconfirmed", defaultValue: "Still muted. The volume change is not yet confirmed")
        case .unmutedVolumeUnconfirmed: String(localized: "volume.unmuted_unconfirmed", defaultValue: "Unmuted. The volume change is not yet confirmed")
        case .stillMuted: String(localized: "volume.still_muted", defaultValue: "Volume adjusted. The device is still muted")
        case .muteUnknown: String(localized: "volume.mute_unknown", defaultValue: "Volume adjusted. Mute status cannot be confirmed right now")
        case .paused: String(localized: "volume.paused", defaultValue: "Volume control is temporarily unavailable")
        case .closed: String(localized: "volume.closed", defaultValue: "The volume service is closed")
        case .listenerUnavailable: String(localized: "volume.listener_unavailable", defaultValue: "Volume notifications are unavailable. Refreshing periodically")
        }
    }
}

enum AudioVolumeControl: Equatable, Sendable {
    case main
    case virtualMain
    /// Reserved capability shape; channel-only controls currently report an implementation gap.
    case channels([UInt32])
}

enum AudioVolumeCapability: Equatable, Sendable {
    case writable(AudioVolumeControl)
    case unavailable(AudioVolumeIssue)

    var canWrite: Bool {
        if case .writable = self { return true }
        return false
    }
    var issue: AudioVolumeIssue? {
        if case let .unavailable(issue) = self { return issue }
        return nil
    }
}

enum AudioVolumeMuteState: Equatable, Sendable {
    case unmuted, muted, mixed, unsupported, unknown

    var isAudiblyMuted: Bool { self == .muted || self == .mixed }
}

struct AudioVolumeSnapshot: Equatable, Sendable {
    let target: AudioVolumeTarget
    let value: Float?
    let capability: AudioVolumeCapability
    let mute: AudioVolumeMuteState
    let canUnmute: Bool

    init(target: AudioVolumeTarget, value: Float?, capability: AudioVolumeCapability,
         mute: AudioVolumeMuteState = .unknown, canUnmute: Bool = false) {
        self.target = target
        self.value = value
        self.capability = capability
        self.mute = mute
        self.canUnmute = canUnmute
    }
}

struct AudioVolumeWriteResult: Equatable, Sendable {
    let snapshot: AudioVolumeSnapshot
    let issue: AudioVolumeIssue?

    init(snapshot: AudioVolumeSnapshot, issue: AudioVolumeIssue? = nil) {
        self.snapshot = snapshot
        self.issue = issue
    }
}

/// Every listed row is represented, including rows with no safe HAL association.
struct AudioVolumeBinding: Equatable, Sendable {
    let deviceID: String
    let target: AudioVolumeTarget?
    let unavailableReason: AudioVolumeIssue

    init(deviceID: String, target: AudioVolumeTarget?, unavailableReason: AudioVolumeIssue = .identityUnconfirmed) {
        self.deviceID = deviceID
        self.target = target
        self.unavailableReason = unavailableReason
    }
}

struct AudioVolumeRowState: Equatable, Sendable {
    let deviceID: String
    var target: AudioVolumeTarget?
    var snapshot: AudioVolumeSnapshot?
    var draftValue: Float?
    var isReading = false
    var isWriting = false
    var issue: AudioVolumeIssue?

    var value: Float? {
        guard let value = draftValue ?? snapshot?.value, AudioVolumeScalar.validScalar(value) else { return nil }
        return value
    }
    var canWrite: Bool {
        target != nil && snapshot?.target == target && snapshot?.value.map(AudioVolumeScalar.validScalar) == true &&
            snapshot?.capability.canWrite == true
    }
    var percent: Int? {
        guard let value, AudioVolumeScalar.validScalar(value) else { return nil }
        return Int((value * 100).rounded())
    }
    var isMuted: Bool { snapshot?.mute.isAudiblyMuted == true }
}

enum AudioVolumeScalar {
    static func validScalar(_ value: Float) -> Bool { value.isFinite && (0...1).contains(value) }
}
