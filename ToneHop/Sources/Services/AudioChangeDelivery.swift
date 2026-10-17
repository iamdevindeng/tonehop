import Foundation

/// HAL callbacks only invalidate a read; they do not carry individual changes
/// that need replaying. Bound admission before dispatching to the MainActor.
final class AudioChangeDelivery: @unchecked Sendable {
    private enum State { case idle, pending, closed }
    private let lock = NSLock()
    private var state = State.idle
    private let changed: @MainActor @Sendable () -> Void

    init(changed: @escaping @MainActor @Sendable () -> Void) {
        self.changed = changed
    }

    func signal() {
        let shouldSchedule = lock.withLock {
            guard case .idle = state else { return false }
            state = .pending
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            guard let self, self.beginDelivery() else { return }
            self.changed()
        }
    }

    /// Closing and the synchronous handler share MainActor isolation. The lock
    /// only coordinates their admission state with arbitrary callback threads.
    /// This permanently rejects pending/new delivery; it does not undo work
    /// already initiated by an earlier handler or cancel its downstream tasks.
    @MainActor
    func close() {
        lock.withLock { state = .closed }
    }

    @MainActor
    private func beginDelivery() -> Bool {
        lock.withLock {
            guard case .pending = state else { return false }
            // Clear before the synchronous handler so a concurrent callback
            // during handling admits one follow-up, without losing its change.
            state = .idle
            return true
        }
    }
}
