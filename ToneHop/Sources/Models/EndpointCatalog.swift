import Foundation

/// Endpoint activation is not system-default selection. Until a live HAL
/// association is proven, discovered receivers keep their own identities.
enum EndpointCatalog {
    static func routes(from rows: [[String: Any]]) -> (routes: [PrivateAudioRoute], warning: String?) {
        PrivateRouteSnapshotAdapter.endpointRoutes(rows)
    }
}
