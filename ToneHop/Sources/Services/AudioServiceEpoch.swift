import Foundation

enum AudioHardwareEvent: Sendable {
    case changed
    case serviceRestarted(UUID)
}

enum AudioServiceResetError: LocalizedError {
    case serviceChanged
    var errorDescription: String? { String(localized: "audio.service_restarted", defaultValue: "The system audio service restarted. Wait for device status to recover, then try again.") }
}

/// HAL's reset callback revokes the old generation before any actor delivery.
/// The permit shares submission registration with the existing shutdown gate;
/// revocation never claims an already registered native call did not happen.
final class AudioServiceEpoch: @unchecked Sendable {
    struct Lease: Sendable {
        let id = UUID()
        let permit = AudioMutationPermit()
        func check() throws {
            guard permit.isActive else { throw AudioServiceResetError.serviceChanged }
        }
    }

    private let lock = NSLock()
    private var lease = Lease()
    private var closed = false

    func capture() -> Lease { lock.withLock { lease } }

    @discardableResult
    func reset(ifCurrent expected: UUID) -> UUID? {
        lock.withLock {
            guard !closed, lease.id == expected else { return nil }
            lease.permit.cancel()
            lease = Lease()
            return lease.id
        }
    }

    func close() {
        lock.withLock {
            closed = true
            lease.permit.cancel()
        }
    }
}

/// Only an immutable generation/permit crosses the actor boundary. No HAL or
/// private audio object, runtime or mutable ownership state is task-local.
enum AudioServiceOperation {
    @TaskLocal static var lease: AudioServiceEpoch.Lease?

    static func capture(from epoch: AudioServiceEpoch?) throws -> AudioServiceEpoch.Lease? {
        let captured = lease ?? epoch?.capture()
        try captured?.check()
        return captured
    }
}
