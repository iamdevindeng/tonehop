import Foundation

/// One presentation event, separate from the unresolved reason kept in stores.
/// Repeating the same failed gesture produces a new identity; refreshing its
/// existing explanation does not replay the event.
struct PresentationFailure: Identifiable, Equatable, Sendable {
    let id: UUID
    let message: String

    init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
    }
}
