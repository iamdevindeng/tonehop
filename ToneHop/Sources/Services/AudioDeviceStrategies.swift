import Foundation

/// Select by the capability established by discovery, independent of when or
/// where the device was connected. Request deadlines and readback stay in Store.
@MainActor
struct AudioDeviceStrategies {
    private let systemAudio: SystemAudioDeviceStrategy
    private let privateRoutes: PrivateRouteDeviceStrategy

    init(hardware: any AudioHardwareProviding, routes: any PrivateRouting) {
        systemAudio = SystemAudioDeviceStrategy(hardware: hardware, routes: routes)
        privateRoutes = PrivateRouteDeviceStrategy(routes: routes)
    }

    func select(_ device: AudioDevice, isShuttingDown: @MainActor () -> Bool) async throws {
        try Task.checkCancellation()
        guard !isShuttingDown() else { throw CancellationError() }
        switch device.backend {
        case let .coreAudio(uid):
            try await systemAudio.select(uid: uid, isShuttingDown: isShuttingDown)
        case let .privateRoute(identifier):
            try await privateRoutes.select(identifier: identifier)
        case .unavailable:
            throw AudioServiceError.unavailable(device.unavailableReason ?? String(localized: "audio.switch_not_ready", defaultValue: "This device is not ready to be selected."))
        }
    }
}

/// Built-in, USB and HAL Bluetooth outputs share the same system selection
/// contract. The route service owns any AirPlay references left by a transition.
@MainActor
private struct SystemAudioDeviceStrategy {
    let hardware: any AudioHardwareProviding
    let routes: any PrivateRouting

    func select(uid: String, isShuttingDown: @MainActor () -> Bool) async throws {
        // Capture while the real system route is still selected.
        try await routes.prepareToLeave()
        try Task.checkCancellation()
        guard !isShuttingDown() else { throw CancellationError() }
        do {
            try await hardware.select(uid: uid)
        } catch {
            // A failed HAL call can still have changed system state. The route
            // service reconciles live ownership before removing an owned member.
            if !isShuttingDown() { try? await routes.completedLeave() }
            throw error
        }
        // A timeout still reconciles the submitted leave. Shutdown releases
        // references without disconnecting the user's current receiver.
        if !isShuttingDown() { try await routes.completedLeave() }
    }
}

/// AirPlay uses its retained-route lifecycle; other discovered private routes
/// continue through their service capability without bypassing its validation.
@MainActor
private struct PrivateRouteDeviceStrategy {
    let routes: any PrivateRouting

    func select(identifier: String) async throws {
        try await routes.select(identifier: identifier)
    }
}
