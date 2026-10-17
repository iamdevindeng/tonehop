import Foundation

/// A reversible interaction creates a new permit after resuming; an old permit
/// never reopens. Cancellation and submission registration share its short lock.
final class AudioMutationPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func cancel() { lock.withLock { active = false } }

    var isActive: Bool { lock.withLock { active } }

    fileprivate func registerIfActive(_ register: () -> Bool) -> Bool {
        lock.withLock { active && register() }
    }
}

/// Visible immediately across MainActor, the HAL actor, and the native audio
/// thread. Writes close before cancelling tasks; accepted submissions finish
/// outside the lock and drain before their resources are released.
final class AudioShutdownSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSubmissions = 0
    private var submissionDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private enum Phase { case running, closed }
    private var phase = Phase.running

    var isShuttingDown: Bool { lock.withLock { phase != .running } }

    func begin() { lock.withLock { phase = .closed } }

    /// The short lock registers an irrevocable submission, never a system call.
    /// Closing rejects new registrations; accepted work may finish after close.
    /// Callers must drain before releasing resources used by those operations.
    func performIfRunning(permit: AudioMutationPermit? = nil, servicePermit: AudioMutationPermit? = nil,
                          _ operation: () -> Void) -> Bool {
        let register = {
            self.lock.withLock {
                guard self.phase == .running else { return false }
                self.activeSubmissions += 1
                return true
            }
        }
        let registerRequest = { permit.map { $0.registerIfActive(register) } ?? register() }
        let accepted = servicePermit.map { $0.registerIfActive(registerRequest) } ?? registerRequest()
        guard accepted else { return false }
        defer {
            let waiters = lock.withLock {
                activeSubmissions -= 1
                return takeSubmissionWaitersIfDrained()
            }
            for waiter in waiters { waiter.resume() }
        }
        operation()
        return true
    }

    /// Call begin() before draining on shutdown. Cancelling this wait cannot
    /// turn a pending remote effect into absence or release its resources.
    func drainSubmissions() async {
        await withCheckedContinuation { continuation in
            let drained = lock.withLock {
                guard activeSubmissions != 0 else { return true }
                submissionDrainWaiters.append(continuation)
                return false
            }
            if drained { continuation.resume() }
        }
    }

    /// Lock must already be held; continuations are resumed by the caller outside it.
    private func takeSubmissionWaitersIfDrained() -> [CheckedContinuation<Void, Never>] {
        guard activeSubmissions == 0 else { return [] }
        let waiters = submissionDrainWaiters
        submissionDrainWaiters.removeAll()
        return waiters
    }

    func checkRunning() throws {
        guard !isShuttingDown else { throw CancellationError() }
    }
}

