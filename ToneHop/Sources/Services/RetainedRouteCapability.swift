import Foundation

/// A retained reference alone grants neither a listing nor selected state.
/// A separate, twice-validated current descriptor can keep a usable receiver
/// visible while discovery is warming up. The captured UID alone never binds HAL.
struct RetainedRouteCapability: Sendable, Equatable {
    static let preparationHint = String(localized: "audio.airplay_preparation", defaultValue: "Keep ToneHop running and select this device once in the macOS Sound menu to enable switching during this session.")

    let identifier: String
    let canSelect: Bool
    let reason: String?
    /// Fresh directory identity, independent of captured-stream reuse rights.
    /// It never grants selection, volume, or ownership of the associated stream.
    let associatedUID: String?
    private let catalogRoute: PrivateAudioRoute?

    /// Available only after the native bridge's current double read and the
    /// adapter's ready/unselected/UID checks. A bare canSelect flag is weaker.
    var validatedUnselectedRoute: PrivateAudioRoute? { catalogRoute }

    init?(snapshot: [String: Any]) {
        guard let decoded = PrivateRouteSnapshotAdapter.retainedCapability(snapshot) else { return nil }
        self = decoded
    }

    init(identifier: String, canSelect: Bool, reason: String?, associatedUID: String?, catalogRoute: PrivateAudioRoute?) {
        self.identifier = identifier
        self.canSelect = canSelect
        self.reason = reason
        self.associatedUID = associatedUID
        self.catalogRoute = catalogRoute
    }

    static func applying(_ capability: Self?, to routes: [PrivateAudioRoute],
                         allowUndiscoveredRoute: Bool = true) -> [PrivateAudioRoute] {
        var result = routes.map { route in
            guard route.transportKind == .airplay else { return route }
            let matching = capability?.identifier == route.identifier ? capability : nil
            // Keep explicit discovery/selection evidence authoritative. This
            // association only folds an unselected, still-live transport into
            // its receiver row; it must never manufacture selection evidence.
            let uid = !route.isSelected && (route.uid == nil || route.uid?.isEmpty == true)
                ? (matching?.associatedUID ?? route.uid) : route.uid
            return PrivateAudioRoute(identifier: route.identifier, name: route.name, uid: uid,
                                     isSelected: route.isSelected, transportKind: route.transportKind,
                                     selectionCapability: matching?.canSelect == true ? .retainedAirPlay : .unavailable,
                                     unavailableReason: matching?.reason ?? preparationHint, icon: route.icon)
        }
        if allowUndiscoveredRoute, let held = capability?.catalogRoute,
           !routes.contains(where: { $0.identifier == held.identifier }),
           !routes.contains(where: \.isSelected),
           !routes.contains(where: { held.uid != nil && $0.uid == held.uid }) {
            result.append(held)
        }
        return result
    }
}
