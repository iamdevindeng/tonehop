import Foundation

enum AudioDiscoveryPresence: Equatable, Sendable {
    case found, missing, unconfirmed
}

/// A value-only observation of a source's raw identities. A filtered display
/// list, writable capability, or retained descriptor cannot prove absence.
struct AudioDiscoverySourceInventory: Equatable, Codable, Sendable {
    let observedIdentifiers: Set<String>
    let conflictedIdentifiers: Set<String>
    let isComplete: Bool

    init(observedIdentifiers: Set<String> = [], conflictedIdentifiers: Set<String> = [],
         isComplete: Bool = false) {
        self.observedIdentifiers = observedIdentifiers
        self.conflictedIdentifiers = conflictedIdentifiers
        self.isComplete = isComplete
    }

    static let unconfirmed = Self()

    func presence(of identifier: String) -> AudioDiscoveryPresence {
        guard !identifier.isEmpty else { return .unconfirmed }
        // Repeated IDs still establish presence. They cannot prove persistent
        // binding uniqueness, revoke an independently verified live capability,
        // or establish that some other saved identity is absent.
        if observedIdentifiers.contains(identifier) { return .found }
        return isComplete && conflictedIdentifiers.isEmpty ? .missing : .unconfirmed
    }
}

struct AudioDiscoveryInventory: Equatable, Sendable {
    let hal: AudioDiscoverySourceInventory
    let receivers: AudioDiscoverySourceInventory

    init(hal: AudioDiscoverySourceInventory = .unconfirmed,
         receivers: AudioDiscoverySourceInventory = .unconfirmed) {
        self.hal = hal
        self.receivers = receivers
    }

    static let unconfirmed = Self()

    func presence(of target: AudioTargetIdentity) -> AudioDiscoveryPresence {
        switch target {
        case let .hal(uid): hal.presence(of: uid)
        case let .receiver(identifier): receivers.presence(of: identifier)
        }
    }

    static func merge(hal: CoreAudioSnapshot, routes: PrivateRouteSnapshot) -> Self {
        var receivers = routes.discovery.observedIdentifiers
        let identityGroups = Dictionary(grouping: routes.routes, by: \.identifier)
        let uidGroups = Dictionary(grouping: routes.routes.filter { $0.uid?.isEmpty == false }, by: { $0.uid! })
        var conflicts = routes.discovery.conflictedIdentifiers
        conflicts.formUnion(identityGroups.filter { $0.key.isEmpty || $0.value.count != 1 }.keys)
        for group in uidGroups.values where Set(group.map(\.identifier)).count > 1 {
            conflicts.formUnion(group.map(\.identifier))
        }
        // Actual HAL presence can protect a currently associated receiver even
        // when it has moved out of discovery. Retained references alone cannot.
        var associatedUIDs = Set<String>()
        for route in routes.routes {
            guard !conflicts.contains(route.identifier),
                  let uid = route.uid, hal.confirmedDeviceObjects[uid] != nil,
                  hal.devices.contains(where: { $0.backend == .coreAudio(uid: uid) }) else { continue }
            receivers.insert(route.identifier)
            associatedUIDs.insert(uid)
        }
        if let selected = routes.selectedVolumeAssociation,
           !conflicts.contains(selected.identifier),
           hal.confirmedDeviceObjects[selected.uid] != nil,
           hal.devices.contains(where: { $0.backend == .coreAudio(uid: selected.uid) }) {
            receivers.insert(selected.identifier)
            associatedUIDs.insert(selected.uid)
        }
        // An anonymous live AirPlay transport may belong to the saved receiver.
        // Until its full identity arrives, absence cannot safely be concluded.
        let hasUnidentifiedAirPlay = hal.devices.contains { device in
            guard device.transport == .airplay, case let .coreAudio(uid) = device.backend else { return false }
            return !associatedUIDs.contains(uid)
        }
        // Raw UID presence survives display filtering. If an associated object
        // is still enumerated but its output row is unavailable, preserve the
        // receiver as unconfirmed without granting a live route capability.
        let hasUnprojectedAssociation = routes.routes.contains { route in
            guard let uid = route.uid,
                  hal.discovery.observedIdentifiers.contains(uid) || hal.confirmedDeviceObjects[uid] != nil else { return false }
            return !hal.devices.contains(where: { $0.backend == .coreAudio(uid: uid) })
        }
        return Self(hal: hal.discovery, receivers: AudioDiscoverySourceInventory(
            observedIdentifiers: receivers,
            conflictedIdentifiers: conflicts,
            isComplete: routes.discovery.isComplete && hal.discovery.isComplete && hal.isOutputInventoryComplete
                && !hasUnidentifiedAirPlay && !hasUnprojectedAssociation))
    }
}
