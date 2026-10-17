import Foundation

/// A fresh system association identifies a receiver's surviving HAL stream.
/// It supplies identity for catalog merging only. Switching requires a separate
/// validated capability, and selection requires its own strict readback.
struct ExistingSystemStreamAssociation: Sendable, Equatable {
    let identifier: String
    let uid: String
    let aggregateIdentifier: String
    let contextIdentifier: String

    init?(snapshot: [String: Any]) {
        guard let decoded = PrivateRouteSnapshotAdapter.existingStreamAssociation(snapshot) else { return nil }
        self = decoded
    }

    init(identifier: String, uid: String, aggregateIdentifier: String, contextIdentifier: String) {
        self.identifier = identifier
        self.uid = uid
        self.aggregateIdentifier = aggregateIdentifier
        self.contextIdentifier = contextIdentifier
    }

    static func applying(_ association: Self?, to routes: [PrivateAudioRoute]) -> [PrivateAudioRoute] {
        guard let association,
              routes.filter({ $0.identifier == association.identifier }).count == 1 else { return routes }
        return routes.map { route in
            guard route.identifier == association.identifier, route.transportKind == .airplay, !route.isSelected,
                  route.uid == nil || route.uid == "" || route.uid == association.uid else { return route }
            return PrivateAudioRoute(identifier: route.identifier, name: route.name, uid: association.uid,
                                     isSelected: route.isSelected, transportKind: route.transportKind,
                                     selectionCapability: route.selectionCapability, unavailableReason: route.unavailableReason,
                                     icon: route.icon)
        }
    }
}
