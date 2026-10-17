#if DEBUG
import AppKit
import Foundation

/// Explicitly selected by --preview-r08-for-testing. These sample names and
/// symbols belong only to this in-memory visual fixture, never production icon
/// policy. The real stores/coordinator/panel run with every system seam injected.
@MainActor
enum R08PreviewFixture {
    static func make(quitMenu: NSMenu) -> (store: AudioStore, interactions: AudioInteractionCoordinator) {
        let state = R08PreviewState()
        let hardware = R08PreviewHardware(state: state)
        let routes = R08PreviewRoutes(state: state)
        let audio = AudioStore(hardware: hardware, routes: routes)
        let volume = AudioVolumeStore(provider: R08PreviewVolume(state: state), resolveTarget: { [weak audio] id in
            guard let audio else { throw CancellationError() }
            return try await audio.resolveVolumeTarget(deviceID: id)
        })
        let shortcuts = ShortcutStore(selectTarget: { [weak audio] target, request in
            audio?.select(target: target, request: request)
        }, preferences: R08PreviewPreferences(bindings: sampleBindings()),
           registrar: R08PreviewRegistrar(), menuConflict: { shortcut in
            StatusBarController.shortcutConflict(shortcut, quitMenu: quitMenu, mainMenu: NSApp.mainMenu)
        })
        return (audio, AudioInteractionCoordinator(audio: audio, shortcuts: shortcuts, volume: volume))
    }

    private static func sampleBindings() -> [ShortcutBinding] {
        let samples: [(AudioTargetIdentity, UInt16, String)] = [
            (.hal(uid: R08PreviewState.macUID), 18, "Mac mini Speakers"),
            (.hal(uid: R08PreviewState.displayUID), 19, "Redmi 27 NU"),
            (.hal(uid: R08PreviewState.virtualUID), 20, "OrayVirtualAudioDevice"),
            (.receiver(identifier: R08PreviewState.bedroomID), 21, "Bedroom"),
            (.hal(uid: "r08-preview-missing-headphones"), 23, "EDIFIER W820NB"),
        ]
        // All five literal key codes and Command combinations satisfy the same
        // constructor used by production. No default bindings are added there.
        return samples.map { target, keyCode, name in
            ShortcutBinding(target: target, shortcut: try! DeviceShortcut(keyCode: keyCode, modifiers: .command),
                            lastKnownName: name)
        }
    }
}

@MainActor
private final class R08PreviewState {
    static let macUID = "r08-preview-mac"
    static let displayUID = "r08-preview-display"
    static let virtualUID = "r08-preview-virtual"
    static let bedroomUID = "r08-preview-bedroom-stream"
    static let bedroomID = "r08-preview-bedroom"

    var selectedUID = R08PreviewState.bedroomUID
    var values: [String: Float] = [R08PreviewState.macUID: 0.35, R08PreviewState.virtualUID: 0,
                                 R08PreviewState.bedroomUID: 0.65]
    var failedBedroomSelection = false
    var hardwareChanged: (@Sendable () -> Void)?
    var volumeChanged: (@Sendable () -> Void)?

    var halDevices: [AudioDevice] {
        [
            AudioDevice(id: "hal:\(Self.macUID)", name: "Mac mini Speakers", transport: .speaker,
                        backend: .coreAudio(uid: Self.macUID), shortcutTarget: .hal(uid: Self.macUID),
                        icon: .systemSymbol("macmini.fill")),
            AudioDevice(id: "hal:\(Self.displayUID)", name: "Redmi 27 NU", transport: .display,
                        backend: .coreAudio(uid: Self.displayUID), shortcutTarget: .hal(uid: Self.displayUID),
                        icon: .systemSymbol("display")),
            AudioDevice(id: "hal:\(Self.virtualUID)", name: "OrayVirtualAudioDevice", transport: .virtual,
                        backend: .coreAudio(uid: Self.virtualUID), shortcutTarget: .hal(uid: Self.virtualUID),
                        icon: .systemSymbol("speaker.wave.2.fill")),
            AudioDevice(id: "hal:\(Self.bedroomUID)", name: "AirPlay", transport: .airplay,
                        backend: .coreAudio(uid: Self.bedroomUID)),
        ]
    }

    func halSnapshot() -> CoreAudioSnapshot {
        CoreAudioSnapshot(devices: halDevices, currentDeviceID: "hal:\(selectedUID)",
            systemSoundDeviceID: "hal:\(Self.macUID)", warnings: [],
            confirmedDeviceObjects: [Self.macUID: 1, Self.displayUID: 2, Self.virtualUID: 3, Self.bedroomUID: 4],
            discovery: AudioDiscoverySourceInventory(observedIdentifiers:
                [Self.macUID, Self.displayUID, Self.virtualUID, Self.bedroomUID], isComplete: true),
            isOutputInventoryComplete: true)
    }

    func routeSnapshot() -> PrivateRouteSnapshot {
        let selected = selectedUID == Self.bedroomUID
        return PrivateRouteSnapshot(routes: [PrivateAudioRoute(identifier: Self.bedroomID, name: "Bedroom",
            uid: Self.bedroomUID, isSelected: selected, canSelect: true, transport: "airplay",
            icon: .systemSymbol("homepodmini.fill"))], warning: nil,
            diagnostics: "DEBUG r08 isolated visual fixture; no audio/hotkeys/files",
            selectedVolumeAssociation: selected
                ? SystemRouteVolumeAssociation(identifier: Self.bedroomID, uid: Self.bedroomUID) : nil,
            confirmedShortcutIdentifiers: [Self.bedroomID],
            discovery: AudioDiscoverySourceInventory(observedIdentifiers: [Self.bedroomID], isComplete: true))
    }
}

@MainActor
private final class R08PreviewHardware: AudioHardwareProviding {
    private let state: R08PreviewState
    private nonisolated let gate = AudioShutdownSignal()

    init(state: R08PreviewState) { self.state = state }
    nonisolated func beginShutdown() { gate.begin() }
    func snapshot() async throws -> CoreAudioSnapshot { try gate.checkRunning(); return state.halSnapshot() }
    func builtInSpeaker() async throws -> AudioDevice { try gate.checkRunning(); return state.halDevices[0] }

    func select(uid: String) async throws {
        try Task.checkCancellation()
        try gate.checkRunning()
        guard state.halDevices.contains(where: { $0.backend == .coreAudio(uid: uid) }) else {
            throw AudioServiceError.targetMissing
        }
        // Ordinary clicks on Redmi produce a failure while Bedroom remains the
        // actual fixture output. Other local rows switch only this memory state.
        if uid == R08PreviewState.displayUID {
            throw AudioServiceError.unavailable(String(localized: "ui.preview.display_failure", defaultValue: "Isolated preview: display output switch failed."))
        }
        guard gate.performIfRunning({ state.selectedUID = uid }) else { throw CancellationError() }
        state.hardwareChanged?()
    }

    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws {
        try gate.checkRunning()
        state.hardwareChanged = changed
    }
    func stopObserving() async { state.hardwareChanged = nil; await gate.drainSubmissions() }
}

@MainActor
private final class R08PreviewRoutes: PrivateRouting {
    var onChange: (() -> Void)?
    private let state: R08PreviewState
    private var closed = false

    init(state: R08PreviewState) { self.state = state }
    func start() {}
    func stop() { closed = true; onChange = nil }
    func beginShutdown() { closed = true }
    func snapshot() -> PrivateRouteSnapshot { state.routeSnapshot() }
    func freshSnapshot() async -> PrivateRouteSnapshot { snapshot() }
    func systemOutputDidChange() {}

    func select(identifier: String) async throws {
        try Task.checkCancellation()
        guard !closed, identifier == R08PreviewState.bedroomID else { throw CancellationError() }
        // After a successful local click, the first Bedroom click fails; the
        // next ordinary retry succeeds, exercising persistent cause resolution.
        if !state.failedBedroomSelection {
            state.failedBedroomSelection = true
            throw AudioServiceError.unavailable(String(localized: "ui.preview.bedroom_failure", defaultValue: "Isolated preview: switching to Bedroom failed."))
        }
        state.selectedUID = R08PreviewState.bedroomUID
        onChange?()
    }
    func prepareToLeave() async throws { if closed { throw CancellationError() } }
    func completedLeave() async throws {}
    func ownedStreamForExit() async throws -> OwnedRouteExitEvidence? { nil }
    func shutdown() async throws { stop() }
}

@MainActor
private final class R08PreviewVolume: AudioVolumeProviding {
    private let state: R08PreviewState
    private nonisolated let gate = AudioShutdownSignal()

    init(state: R08PreviewState) { self.state = state }

    func readVolume(for target: AudioVolumeTarget) async throws -> AudioVolumeSnapshot {
        try Task.checkCancellation()
        try gate.checkRunning()
        guard state.halDevices.contains(where: { $0.backend == .coreAudio(uid: target.uid) }) else {
            throw AudioVolumeIssue.identityChanged
        }
        if target.uid == R08PreviewState.displayUID {
            return AudioVolumeSnapshot(target: target, value: nil, capability: .unavailable(.unsupported), mute: .unsupported)
        }
        return AudioVolumeSnapshot(target: target, value: state.values[target.uid], capability: .writable(.main),
                                   mute: .unmuted, canUnmute: false)
    }

    func setVolume(_ value: Float, for target: AudioVolumeTarget, permit: AudioMutationPermit) async throws -> AudioVolumeWriteResult {
        try Task.checkCancellation()
        try gate.checkRunning()
        guard AudioVolumeScalar.validScalar(value) else { throw AudioVolumeIssue.invalidValue }
        let before = try await readVolume(for: target)
        guard before.capability.canWrite else { throw AudioVolumeIssue.unsupported }
        // Every Bedroom adjustment returns valid unchanged readback plus a
        // failure, so a complete drag/end-edit transaction leaves a stable
        // failure scene for GUI inspection. Other sliders succeed in memory.
        var failed = false
        guard gate.performIfRunning(permit: permit, {
            if target.uid == R08PreviewState.bedroomUID { failed = true }
            else { state.values[target.uid] = value }
        }) else { throw CancellationError() }
        if failed {
            return AudioVolumeWriteResult(snapshot: before, issue: .writeFailed(-1))
        }
        state.volumeChanged?()
        return AudioVolumeWriteResult(snapshot: try await readVolume(for: target))
    }

    func observeVolumeChanges(targets: [AudioVolumeTarget], changed: @escaping @Sendable () -> Void) async throws {
        try gate.checkRunning()
        state.volumeChanged = changed
    }
    func stopObservingVolume() async { state.volumeChanged = nil; await gate.drainSubmissions() }
}

private actor R08PreviewPreferences: ShortcutPreferencesProviding {
    private var bindings: [ShortcutBinding]
    init(bindings: [ShortcutBinding]) { self.bindings = bindings }
    func load() async throws -> [ShortcutBinding]? { bindings }
    func save(_ bindings: [ShortcutBinding]) async throws {
        try ShortcutPreferences.validate(bindings)
        self.bindings = bindings
    }
}

@MainActor
private final class R08PreviewRegistrar: GlobalShortcutRegistering {
    var onPress: ((GlobalShortcutRegistration) -> Void)?
    private var entries: [GlobalShortcutRegistration: DeviceShortcut] = [:]
    private var closed = false
    func register(_ shortcut: DeviceShortcut) throws -> GlobalShortcutRegistration {
        guard !closed else { throw ShortcutError.closed }
        guard !entries.values.contains(shortcut) else { throw ShortcutError.registration(operation: String(localized: "ui.preview.registration", defaultValue: "Isolated preview registration"), status: -9878) }
        let token = GlobalShortcutRegistration()
        entries[token] = shortcut
        return token
    }
    func unregister(_ registration: GlobalShortcutRegistration) throws { entries[registration] = nil }
    func systemShortcuts() throws -> Set<DeviceShortcut> { [] }
    func retryFailedCleanup(for shortcut: DeviceShortcut?) throws {}
    func setDeliveryEnabled(_ enabled: Bool) {}
    func close() throws { closed = true; entries = [:]; onPress = nil }
}
#endif
