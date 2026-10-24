import AppKit

/// Connects independently owned stores. It controls admission/drain only, never
/// device identity, route ownership, hot-key transactions or volume capability.
@MainActor
final class AudioInteractionCoordinator: NSObject {
    let shortcuts: ShortcutStore
    let volume: AudioVolumeStore
    private let audio: AudioStore
    private enum PauseReason: Hashable { case switching, quitting, sleep, serviceReset }
    private var pauses = Set<PauseReason>()
    private var closed = false
    var onShortcutFailure: ((AudioSelectionResult) -> Void)?
    /// The menu-bar owner supplies presentation; stores never retain windows.
    var presentRecordRemoval: ((ShortcutDeletionRequest) async -> Bool)?
    var cancelRecordRemoval: (() -> Void)?

    init(audio: AudioStore, shortcuts: ShortcutStore, volume: AudioVolumeStore) {
        self.audio = audio
        self.shortcuts = shortcuts
        self.volume = volume
        super.init()
        audio.onCatalogChange = { [weak self] devices, bindings in
            guard let self else { return }
            self.shortcuts.updateDevices(devices, discovery: self.audio.discoveryInventory)
            self.volume.updateBindings(bindings)
        }
        audio.onSelectionResult = { [weak self] result in
            guard let self, self.shortcuts.handleSelectionResult(result) else { return }
            self.onShortcutFailure?(result)
        }
        audio.onInteractionChange = { [weak self] phase, suspended in self?.setSuspended(phase, suspended) }
        audio.onServiceRecoveryChange = { [weak self] recovering in
            self?.setVolumePaused(.serviceReset, recovering)
        }
        audio.drainInteractions = { [weak self] in await self?.volume.drain() }
        audio.onShutdown = { [weak self] in self?.closeAdmission() }
        audio.closeInteractions = { [weak self] in
            guard let self else { return }
            await self.volume.shutdown()
            await self.shortcuts.drain()
        }
    }

    func start() {
        guard !closed else { return }
        shortcuts.updateDevices(audio.devices, discovery: audio.discoveryInventory)
        shortcuts.start()
        volume.updateBindings(audio.volumeBindings)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    func setMenuTracking(_ active: Bool) { shortcuts.setSuspended(.menu, active) }
    func setPanelVisible(_ visible: Bool) { volume.setPollingActive(visible) }
    func cancelRecording() { shortcuts.cancelRecording() }

    func removeRecord(_ binding: ShortcutBinding) {
        guard !closed, let request = shortcuts.requestRecordRemoval(bindingID: binding.id) else { return }
        shortcuts.setSuspended(.modal, true)
        Task { [weak self] in
            guard let self else { return }
            let confirmed = !self.closed && !self.audio.isPreparingToQuit
                ? await self.presentRecordRemoval?(request) ?? false : false
            if confirmed {
                // The Store rechecks current presence and revision at admission.
                if !shortcuts.confirmDeletion(request) { shortcuts.cancelDeletion(request) }
            }
            else { shortcuts.cancelDeletion(request) }
            shortcuts.setSuspended(.modal, false)
        }
    }

    private func setSuspended(_ phase: AudioInteractionPhase, _ suspended: Bool) {
        guard !closed else { return }
        if phase == .quitting, suspended { cancelRecordRemoval?() }
        let reason: PauseReason = phase == .switching ? .switching : .quitting
        shortcuts.setSuspended(phase == .switching ? .switching : .quitting, suspended)
        setVolumePaused(reason, suspended)
    }

    private func setVolumePaused(_ reason: PauseReason, _ paused: Bool) {
        let wasPaused = !pauses.isEmpty
        if paused { pauses.insert(reason) } else { pauses.remove(reason) }
        if !pauses.isEmpty { volume.pause() }
        else if wasPaused { volume.resume() }
    }

    func closeAdmission() {
        guard !closed else { return }
        closed = true
        cancelRecordRemoval?()
        volume.pause()
        shortcuts.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        onShortcutFailure = nil
        presentRecordRemoval = nil
        cancelRecordRemoval = nil
    }

    @objc private func willSleep() {
        guard !closed else { return }
        shortcuts.setSuspended(.sleep, true)
        setVolumePaused(.sleep, true)
    }

    @objc private func didWake() {
        guard !closed else { return }
        audio.refresh()
        shortcuts.setSuspended(.sleep, false)
        setVolumePaused(.sleep, false)
    }
}

@MainActor
enum RecordRemovalAlerts {
    static func confirmation(name: String) -> RecordRemovalPanel {
        RecordRemovalPanel(name: name)
    }
}
