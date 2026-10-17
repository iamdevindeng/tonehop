import Foundation

/// A value-only fingerprint. Any missing/conflicting source removes the binding;
/// a later match receives a new generation rather than reviving queued writes.
struct AudioVolumeIdentity: Equatable, Sendable {
    let uid: String
    let objectID: UInt32
    let receiverID: String?

    static func resolve(_ device: AudioDevice, hal: CoreAudioSnapshot,
                        routes: PrivateRouteSnapshot) -> Self? {
        switch device.backend {
        case let .coreAudio(uid):
            guard device.transport != .airplay,
                  let objectID = hal.confirmedDeviceObjects[uid],
                  hal.devices.filter({ $0.id == device.id && $0.backend == .coreAudio(uid: uid) }).count == 1 else { return nil }
            return Self(uid: uid, objectID: objectID, receiverID: nil)
        case let .privateRoute(identifier):
            guard let source = routes.selectedVolumeAssociation, source.identifier == identifier,
                  !source.uid.isEmpty, let objectID = hal.confirmedDeviceObjects[source.uid],
                  hal.currentDeviceID == "hal:\(source.uid)",
                  hal.devices.filter({ $0.backend == .coreAudio(uid: source.uid) }).count == 1 else { return nil }
            let matches = routes.routes.filter { $0.identifier == identifier }
            guard matches.count == 1, let route = matches.first, route.isSelected, route.uid == source.uid,
                  !routes.routes.contains(where: { $0.identifier != identifier && $0.uid == source.uid }) else { return nil }
            return Self(uid: source.uid, objectID: objectID, receiverID: identifier)
        case .unavailable: return nil
        }
    }

    static func unavailableReason(_ device: AudioDevice, routes: PrivateRouteSnapshot) -> AudioVolumeIssue {
        if case let .privateRoute(identifier) = device.backend {
            let matches = routes.routes.filter { $0.identifier == identifier }
            if matches.count == 1, matches[0].uid?.isEmpty != false { return .notConnected }
        }
        return .identityUnconfirmed
    }
}
