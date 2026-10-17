import Foundation

enum AudioTransport: String, Codable, Sendable {
    case speaker, display, bluetooth, usb, airplay, virtual, unknown

    var symbolName: String {
        switch self {
        case .speaker: "speaker.wave.2.fill"
        case .display: "display"
        case .bluetooth: "headphones"
        case .usb: "hifispeaker.fill"
        case .airplay: "airplay.audio"
        case .virtual: "waveform"
        case .unknown: "speaker.wave.2"
        }
    }
}

enum AudioBackend: Equatable, Codable, Sendable {
    case coreAudio(uid: String)
    case privateRoute(identifier: String)
    case unavailable
}

/// Persist receiver identity, never an AirPlay transport's temporary UID.
/// Only the evidence-producing catalog assigns this independent capability.
enum AudioTargetIdentity: Hashable, Codable, Sendable {
    case hal(uid: String)
    case receiver(identifier: String)
}

struct AudioDevice: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let name: String
    let transport: AudioTransport
    let backend: AudioBackend
    var isAvailable: Bool = true
    var unavailableReason: String? = nil
    var shortcutTarget: AudioTargetIdentity? = nil
    var icon: AudioDeviceIcon = .fallback

    /// Display/record association only; this never grants shortcut or switch capability.
    func represents(_ target: AudioTargetIdentity) -> Bool {
        switch (backend, target) {
        case let (.coreAudio(uid), .hal(targetUID)): uid == targetUID
        case let (.privateRoute(identifier), .receiver(targetID)): identifier == targetID
        default: false
        }
    }

    var representedIdentity: AudioTargetIdentity? {
        switch backend {
        case let .coreAudio(uid): .hal(uid: uid)
        case let .privateRoute(identifier): .receiver(identifier: identifier)
        case .unavailable: nil
        }
    }
}

struct CoreAudioSnapshot: Codable, Sendable {
    let devices: [AudioDevice]
    let currentDeviceID: String?
    let systemSoundDeviceID: String?
    let warnings: [String]
    /// Complete raw-inventory uniqueness, before filtering and deduplication.
    /// Missing evidence is deliberately not inferred from the visible rows.
    var confirmedDeviceObjects: [String: UInt32] = [:]
    var discovery: AudioDiscoverySourceInventory = .unconfirmed
    /// Every raw object was either confirmed as an output row or explicitly
    /// excluded (for example input-only/hidden). Getter failure is not exclusion.
    var isOutputInventoryComplete: Bool = false
    var serviceGeneration: UUID? = nil
}

struct CoreAudioObjectIdentity: Equatable, Sendable {
    let objectID: UInt32
    let uid: String
}

enum CoreAudioIdentityInventory {
    static func discovery(_ identities: [CoreAudioObjectIdentity], complete: Bool) -> AudioDiscoverySourceInventory {
        let groups = Dictionary(grouping: identities.filter { !$0.uid.isEmpty }, by: \.uid)
        let conflicts = Set(groups.filter { $0.value.count != 1 }.keys)
        return AudioDiscoverySourceInventory(observedIdentifiers: Set(groups.keys),
            conflictedIdentifiers: conflicts,
            isComplete: complete && identities.allSatisfy { !$0.uid.isEmpty }
                && Set(identities.map(\.objectID)).count == identities.count)
    }

    static func confirmedObjects(_ identities: [CoreAudioObjectIdentity], complete: Bool) -> [String: UInt32] {
        guard complete, identities.allSatisfy({ !$0.uid.isEmpty }),
              Set(identities.map(\.objectID)).count == identities.count else { return [:] }
        return Dictionary(grouping: identities, by: \.uid)
            .compactMapValues { $0.count == 1 ? $0.first?.objectID : nil }
    }
}

enum FeedbackKind: String, Codable, Sendable {
    case neutral, progress, success, failure
}

enum AudioServiceError: LocalizedError {
    case system(operation: String, status: Int32)
    case targetMissing
    case ambiguousIdentity
    case unavailable(String)
    /// The backend submitted a selection but could not confirm its result.
    /// Keep that outcome distinct from a refusal before submission.
    case selectionUnconfirmed(String)

    var errorDescription: String? {
        switch self {
        case let .system(operation, status): String(localized: "audio.system_operation_failed", defaultValue: "\(operation) failed (\(Int(status)))")
        case .targetMissing: String(localized: "audio.target_missing", defaultValue: "The device is offline. Refresh and try again.")
        case .ambiguousIdentity: String(localized: "audio.identity_ambiguous", defaultValue: "The device could not be uniquely identified. Switching was cancelled.")
        case let .unavailable(reason): reason
        case let .selectionUnconfirmed(reason): reason
        }
    }
}
