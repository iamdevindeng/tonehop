import Foundation

/// Validates the value evidence produced by the read-only native bridge.
/// Activation alone and an old aggregate UID are never selection evidence.
enum SystemAudioSelection {
    static func route(from snapshot: [String: Any]) -> PrivateAudioRoute? {
        PrivateRouteSnapshotAdapter.selectedRoute(snapshot)
    }
}
