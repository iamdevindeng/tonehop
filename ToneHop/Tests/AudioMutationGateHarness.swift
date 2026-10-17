import Foundation
@testable import ToneHop

/// Test-target bridge only: native exception tests exercise the actual Swift
/// admission and drain implementation without exposing production internals.
@objc(THAudioMutationGateHarness)
public final class AudioMutationGateHarness: NSObject, @unchecked Sendable {
    private let signal = AudioShutdownSignal()
    private let serviceEpoch = AudioServiceEpoch()
    private let nativeExecutor = AudioMutationNativeExecutor()

    public override init() {
        super.init()
    }

    @objc(performIfRunning:)
    public func performIfRunning(_ operation: () -> Void) -> Bool {
        signal.performIfRunning(servicePermit: AudioServiceOperation.lease?.permit, operation)
    }

    @objc(hasServiceLease)
    public var hasServiceLease: Bool { AudioServiceOperation.lease != nil }

    @objc(revokeServiceLease)
    public func revokeServiceLease() -> Bool {
        guard let lease = AudioServiceOperation.lease else { return false }
        return serviceEpoch.reset(ifCurrent: lease.id) != nil
    }

    /// Exercise the same task-local hop as PrivateRouteService's native worker.
    /// The Objective-C test then calls a real bridge and re-enters this Swift gate.
    @objc(runWithServiceLease:completion:)
    public func runWithServiceLease(_ operation: @escaping @Sendable () -> Void,
                                    completion: @escaping @Sendable () -> Void) {
        Task { [self] in
            await AudioServiceOperation.$lease.withValue(serviceEpoch.capture()) {
                await nativeExecutor.run(operation)
            }
            completion()
        }
    }

    @objc(close)
    public func close() {
        signal.begin()
    }

    @objc(drainWithCompletion:)
    public func drain(completion: @escaping @Sendable () -> Void) {
        Task { [signal] in
            await signal.drainSubmissions()
            completion()
        }
    }
}

private actor AudioMutationNativeExecutor {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        AudioRouteExecutor.shared.asUnownedSerialExecutor()
    }

    func run(_ operation: @Sendable () -> Void) { operation() }
}
