import Foundation
import Observation
import OSLog

@MainActor
protocol PrivateRouting: AnyObject {
    var onChange: (() -> Void)? { get set }
    func start()
    func bindServiceEpoch(_ epoch: AudioServiceEpoch?)
    func serviceDidRestart()
    func stop()
    func beginShutdown()
    func systemOutputDidChange()
    func setPeriodicObservation(_ active: Bool)
    func snapshot() -> PrivateRouteSnapshot
    func freshSnapshot() async -> PrivateRouteSnapshot
    func select(identifier: String) async throws
    func prepareToLeave() async throws
    func completedLeave() async throws
    func ownedStreamForExit() async throws -> OwnedRouteExitEvidence?
    func shutdown() async throws
}

extension PrivateRouting {
    func bindServiceEpoch(_ epoch: AudioServiceEpoch?) {}
    func serviceDidRestart() {}
    func freshSnapshot() async -> PrivateRouteSnapshot { snapshot() }
    func systemOutputDidChange() {}
    func setPeriodicObservation(_ active: Bool) {}
    func shutdown() async throws { stop() }
    func ownedStreamForExit() async throws -> OwnedRouteExitEvidence? {
        throw AudioServiceError.unavailable(String(localized: "audio.exit_check_unsupported", defaultValue: "The current audio service does not support checking cleanup before quitting."))
    }
}

extension PrivateRouteService: PrivateRouting {}

@MainActor
@Observable
final class AudioStore {
    private(set) var devices: [AudioDevice] = []
    private(set) var discoveryInventory: AudioDiscoveryInventory = .unconfirmed
    private(set) var currentDeviceID: String?
    private(set) var isSwitching = false
    private(set) var isRefreshing = false
    private(set) var feedback = String(localized: "audio.reading_devices", defaultValue: "Loading sound output devices…")
    private(set) var feedbackKind = FeedbackKind.neutral
    private(set) var failureEvent: PresentationFailure?
    private enum FeedbackPresentation {
        case ordinary, targetFailure(String), incomplete, unconfirmed
    }
    private struct TransientFailure {
        let id = UUID()
        let targetID: String?
    }
    private var feedbackPresentation = FeedbackPresentation.ordinary
    var presentationFeedback: String {
        switch feedbackKind {
        case .neutral, .success:
            return devices.isEmpty ? feedback : String(localized: "audio.interaction_hint", defaultValue: "Click to switch. Shortcuts need ⌘ or ⌃")
        case .progress: return feedback
        case .failure:
            switch feedbackPresentation {
            case .ordinary: return feedback
            case let .targetFailure(name): return String(localized: "audio.switch_target_failed", defaultValue: "Could not switch to \(name)")
            case .incomplete: return String(localized: "audio.switch_incomplete", defaultValue: "Switching did not finish")
            case .unconfirmed: return String(localized: "audio.switch_unconfirmed", defaultValue: "Switching result not yet confirmed")
            }
        }
    }
    private(set) var catalogWarning: String?
    private enum QuitState {
        case idle, admitted, checking, awaitingConfirmation(AudioExitPlan), committing
    }
    private var quitState = QuitState.idle
    var isPreparingToQuit: Bool {
        if case .idle = quitState { return false }
        return true
    }

    @ObservationIgnored private let hardware: any AudioHardwareProviding
    @ObservationIgnored private let routes: any PrivateRouting
    @ObservationIgnored private let deviceStrategies: AudioDeviceStrategies
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private let exitCoordinator: AudioExitCoordinator
    @ObservationIgnored private let observerRetryDelay: Duration
    @ObservationIgnored private let pollingInterval: Duration
    @ObservationIgnored private let failureFeedbackDuration: Duration
    @ObservationIgnored private let logger = Logger(subsystem: "com.dengziyi.ToneHop", category: "audio")
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var observationRevision = UUID()
    @ObservationIgnored private var installedObservationRevision: UUID?
    @ObservationIgnored private var nextObserverAttempt = ContinuousClock.now
    @ObservationIgnored private var recoveryGeneration: UUID?
    @ObservationIgnored private var knownServiceGeneration: UUID?
    @ObservationIgnored var onServiceRecoveryChange: ((Bool) -> Void)?
    @ObservationIgnored private var hardwareChangeDelivery: AudioChangeDelivery?
    @ObservationIgnored private var switchTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var feedbackExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var transientFailure: TransientFailure?
    @ObservationIgnored private var shutdownTask: Task<Void, any Error>?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var timedOutRequestID: UUID?
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var snapshotSerial = 0
    @ObservationIgnored private var appliedSnapshotSerial = 0
    @ObservationIgnored private var backgroundReadEpoch = 0
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var started = false
    // Non-panel owners, including diagnostics, retain periodic observation.
    @ObservationIgnored private(set) var isPanelVisible = true
    @ObservationIgnored private var observerWarning: String?
    @ObservationIgnored private var confirmedTargetID: String?
    @ObservationIgnored private var feedbackBeforeCatalogReadFailure: (message: String, kind: FeedbackKind, presentation: FeedbackPresentation)?
    @ObservationIgnored private(set) var lastHardwareSnapshot: CoreAudioSnapshot?
    @ObservationIgnored private(set) var lastRouteSnapshot: PrivateRouteSnapshot?
    private(set) var volumeTargets: [String: AudioVolumeTarget] = [:]
    private(set) var volumeBindings: [AudioVolumeBinding] = []
    @ObservationIgnored private var volumeIdentities: [String: AudioVolumeIdentity] = [:]
    @ObservationIgnored var onCatalogChange: (([AudioDevice], [AudioVolumeBinding]) -> Void)?
    @ObservationIgnored var onSelectionResult: ((AudioSelectionResult) -> Void)?
    @ObservationIgnored var onInteractionChange: ((AudioInteractionPhase, Bool) -> Void)?
    @ObservationIgnored var drainInteractions: (() async -> Void)?
    @ObservationIgnored var onShutdown: (() -> Void)?
    @ObservationIgnored var closeInteractions: (() async -> Void)?
    @ObservationIgnored private var selectionRequest: AudioSelectionRequest?
    @ObservationIgnored private var lastCatalogReadFailure: String?

    init(hardware: any AudioHardwareProviding = CoreAudioService(),
         routes: any PrivateRouting = PrivateRouteService(), timeout: Duration = .seconds(15),
         observerRetryDelay: Duration = .seconds(30), pollingInterval: Duration = .seconds(2),
         failureFeedbackDuration: Duration = .seconds(5)) {
        self.hardware = hardware
        self.routes = routes
        routes.bindServiceEpoch(hardware.serviceEpoch)
        knownServiceGeneration = hardware.serviceEpoch?.capture().id
        self.deviceStrategies = AudioDeviceStrategies(hardware: hardware, routes: routes)
        self.timeout = timeout
        self.exitCoordinator = AudioExitCoordinator(hardware: hardware, routes: routes)
        self.observerRetryDelay = observerRetryDelay
        self.pollingInterval = pollingInterval
        self.failureFeedbackDuration = failureFeedbackDuration
    }

    func start() {
        guard !started, !shuttingDown else { return }
        started = true
        routes.onChange = { [weak self] in self?.refresh() }
        routes.setPeriodicObservation(needsPeriodicRefresh)
        routes.start()
        let delivery = AudioChangeDelivery { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.routes.systemOutputDidChange()
            self.refresh()
        }
        hardwareChangeDelivery = delivery
        updatePeriodicObservation()
    }

    func setPanelVisible(_ visible: Bool) {
        guard !shuttingDown, isPanelVisible != visible else { return }
        isPanelVisible = visible
        updatePeriodicObservation()
    }

    private var needsPeriodicRefresh: Bool {
        isPanelVisible || observerWarning != nil || installedObservationRevision != observationRevision
    }

    private func updatePeriodicObservation() {
        guard started, !shuttingDown else { return }
        routes.setPeriodicObservation(needsPeriodicRefresh)
        guard needsPeriodicRefresh else {
            monitorTask?.cancel()
            monitorTask = nil
            return
        }
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self, pollingInterval] in
            while !Task.isCancelled {
                guard self?.periodicTick() == true else { return }
                do { try await Task.sleep(for: pollingInterval) } catch { return }
            }
        }
    }

    private func periodicTick() -> Bool {
        guard !shuttingDown, needsPeriodicRefresh else { return false }
        ensureHardwareObservation()
        refresh()
        return true
    }

    private func ensureHardwareObservation() {
        guard !shuttingDown, observationTask == nil,
              installedObservationRevision != observationRevision, .now >= nextObserverAttempt,
              let delivery = hardwareChangeDelivery else { return }
        let revision = observationRevision
        observationTask = Task { [weak self, hardware, observerRetryDelay] in
            guard let self else { return }
            defer {
                observationTask = nil
                if observationRevision != revision { ensureHardwareObservation() }
            }
            do {
                try await hardware.observeEvents { [weak self] event in
                    switch event {
                    case .changed: delivery.signal()
                    case let .serviceRestarted(generation):
                        Task { @MainActor [weak self] in self?.serviceDidRestart(generation) }
                    }
                }
                guard !Task.isCancelled, !shuttingDown, observationRevision == revision else { return }
                installedObservationRevision = revision
                observerWarning = nil
                updatePeriodicObservation()
            } catch {
                guard !Task.isCancelled, !shuttingDown, observationRevision == revision else { return }
                observerWarning = String(localized: "audio.notifications_unavailable", defaultValue: "System notifications are unavailable. Refreshing periodically.")
                nextObserverAttempt = .now.advanced(by: observerRetryDelay)
                updatePeriodicObservation()
            }
        }
    }

    private func serviceDidRestart(_ generation: UUID) {
        guard !shuttingDown, generation == hardware.serviceEpoch?.capture().id,
              generation != knownServiceGeneration else { return }
        knownServiceGeneration = generation
        recoveryGeneration = generation
        observationRevision = UUID()
        nextObserverAttempt = .now
        observationTask?.cancel()
        backgroundReadEpoch += 1
        snapshotSerial += 1
        appliedSnapshotSerial = snapshotSerial
        switchTask?.cancel()
        routes.serviceDidRestart()
        lastHardwareSnapshot = nil
        lastRouteSnapshot = nil
        onServiceRecoveryChange?(true)
        publishFailedDiscoveryRead()
        if let selectionRequest {
            setFeedback(AudioServiceResetError.serviceChanged.localizedDescription,
                        kind: .failure, presentation: .unconfirmed)
            completeSelection(selectionRequest, .failed(feedback))
        }
        ensureHardwareObservation()
        refresh()
        updatePeriodicObservation()
    }

    /// Inspection is reversible: no shutdown gates close until consent and
    /// cleanup have completed. In-flight choices finish before inspecting.
    func beginQuitPreparation() {
        guard !shuttingDown, case .idle = quitState else { return }
        quitState = .admitted
        backgroundReadEpoch += 1
        onInteractionChange?(.quitting, true)
    }

    func prepareToQuit() async throws -> AudioExitPlan {
        guard !shuttingDown else { throw CancellationError() }
        if case .idle = quitState { beginQuitPreparation() }
        guard case .admitted = quitState else { throw CancellationError() }
        quitState = .checking
        // Reads started before this quit attempt stay invalid even when cancel
        // or failure has already returned the store to its running state.
        do {
            await drainInteractions?()
            await switchTask?.value
            try Task.checkCancellation()
            guard !shuttingDown else { throw CancellationError() }
            let plan = try await exitCoordinator.prepare()
            quitState = .awaitingConfirmation(plan)
            return plan
        } catch {
            quitState = .idle
            onInteractionChange?(.quitting, false)
            refresh()
            throw error
        }
    }

    func cancelQuit() {
        guard case .awaitingConfirmation = quitState else { return }
        quitState = .idle
        onInteractionChange?(.quitting, false)
        refresh()
    }

    func confirmQuit() async throws {
        guard case let .awaitingConfirmation(plan) = quitState else {
            throw AudioServiceError.unavailable(String(localized: "audio.exit_not_prepared", defaultValue: "The quit request is not ready yet."))
        }
        quitState = .committing
        do {
            try await exitCoordinator.complete(plan)
        } catch {
            quitState = .idle
            onInteractionChange?(.quitting, false)
            refresh()
            throw error
        }
        // Cleanup succeeded. Resource-release errors must not strand a closed
        // store; at this point termination is committed and must finish.
        do { try await shutdown() }
        catch { logger.error("Resource release after confirmed quit: \(error.localizedDescription, privacy: .public)") }
    }

    func stop() {
        let pendingShutdown = beginShutdown()
        Task {
            do { try await pendingShutdown.value }
            catch { logger.error("App resource release failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Finish calls already submitted, then release the App's resources after
    /// the exit coordinator has confirmed any required owned-stream cleanup.
    /// The synchronous signal must precede cancellation so native code can
    /// distinguish termination from a timeout that ordinarily needs rollback.
    func shutdown() async throws {
        try await beginShutdown().value
    }

    private func beginShutdown() -> Task<Void, any Error> {
        if let shutdownTask { return shutdownTask }
        shuttingDown = true
        cancelFeedbackExpiry()
        onShutdown?()
        hardwareChangeDelivery?.close()
        routes.beginShutdown()
        hardware.beginShutdown()
        started = false
        routes.onChange = nil
        let observation = observationTask
        observation?.cancel()
        let monitoring = monitorTask
        monitoring?.cancel()
        let refreshing = refreshTask
        refreshing?.cancel()
        timeoutTask?.cancel()
        let pending = switchTask
        pending?.cancel()
        let task = Task {
            await closeInteractions?()
            await pending?.value
            await refreshing?.value
            await monitoring?.value
            await observation?.value
            monitorTask = nil
            var releaseError: (any Error)?
            do {
                try await routes.shutdown()
            } catch {
                releaseError = error
            }
            // An internal bridge error must not leave listeners running or
            // turn the user's selected receiver into a reason to refuse Quit.
            await hardware.stopObserving()
            if let releaseError { throw releaseError }
        }
        shutdownTask = task
        return task
    }

    func refresh() {
        guard !shuttingDown else { return }
        // Quit reads have their own diagnostics. Keep background HAL/route
        // observations out of the panel until the reversible quit flow ends.
        guard !isPreparingToQuit else { needsRefresh = true; return }
        // HAL can expose the new AirPlay stream before the private worker has
        // published its receiver association. Keep the in-progress view stable
        // instead of briefly drawing both a generic AirPlay and receiver row.
        guard !isSwitching else { needsRefresh = true; return }
        guard refreshTask == nil else {
            needsRefresh = true
            return
        }
        // A refresh started by an old switch's defer is independent work: it
        // must acquire the current service generation, not inherit that request.
        refreshTask = Task { [weak self] in
            await AudioServiceOperation.$lease.withValue(nil) { [weak self] in
                guard let self else { return }
                repeat {
                    guard !isPreparingToQuit else { needsRefresh = true; break }
                    needsRefresh = false
                    do { try await loadSnapshot() }
                    catch {
                        guard !Task.isCancelled, !shuttingDown else { break }
                        guard !isPreparingToQuit else { needsRefresh = true; break }
                        if let failure = error as? SnapshotFailure {
                            guard failure.serial >= appliedSnapshotSerial else { continue }
                            appliedSnapshotSerial = failure.serial
                        }
                        if !isSwitching {
                            if feedbackBeforeCatalogReadFailure == nil {
                                feedbackBeforeCatalogReadFailure = (feedback, feedbackKind, feedbackPresentation)
                            }
                            feedback = error.localizedDescription
                            feedbackKind = .failure
                            feedbackPresentation = .ordinary
                            if lastCatalogReadFailure != feedback {
                                failureEvent = PresentationFailure(message: feedback)
                            }
                            lastCatalogReadFailure = feedback
                        }
                    }
                } while needsRefresh && !Task.isCancelled && !isPreparingToQuit
                refreshTask = nil
            }
        }
    }

    func select(target: AudioTargetIdentity, request: AudioSelectionRequest) {
        guard !isSwitching, !shuttingDown, !isPreparingToQuit, recoveryGeneration == nil else {
            onSelectionResult?(AudioSelectionResult(request: request, outcome: .ignored))
            return
        }
        let matches = devices.filter { $0.shortcutTarget == target }
        guard matches.count == 1, let device = matches.first else {
            let message = matches.isEmpty ? String(localized: "audio.target_offline_or_unconfirmed", defaultValue: "The device is offline or its identity is unconfirmed. Check it and try again.") : AudioServiceError.ambiguousIdentity.localizedDescription
            setFeedback(message, kind: .failure)
            onSelectionResult?(AudioSelectionResult(request: request, outcome: .failed(message)))
            return
        }
        select(device, request: request)
    }

    func select(_ requested: AudioDevice) {
        select(requested, request: AudioSelectionRequest(origin: .pointer))
    }

    private func select(_ requested: AudioDevice, request selection: AudioSelectionRequest) {
        guard !isSwitching, !shuttingDown, !isPreparingToQuit, recoveryGeneration == nil else {
            onSelectionResult?(AudioSelectionResult(request: selection, outcome: .ignored))
            return
        }
        guard let device = devices.first(where: { $0.id == requested.id }), device.isAvailable else {
            let message = requested.unavailableReason ?? String(localized: "audio.device_unavailable", defaultValue: "The device is unavailable. Try again later.")
            setFeedback(message, kind: .failure, presentation: .targetFailure(requested.name),
                        clearWhenSelected: requested.id)
            onSelectionResult?(AudioSelectionResult(request: selection, outcome: .failed(message)))
            return
        }
        // A cached checkmark is only a reason to verify a possible no-op. The
        // system may already have changed output while its notification or our
        // previous directory read is still pending.
        let needsCurrentSelectionCheck = currentDeviceID == device.id
        isSwitching = true
        selectionRequest = selection
        onInteractionChange?(.switching, true)
        if !needsCurrentSelectionCheck {
            confirmedTargetID = nil
            setFeedback(String(localized: "audio.switching_to", defaultValue: "Switching to \(device.name)…"), kind: .progress)
        }
        let request = selection.id
        requestID = request
        timeoutTask = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, requestID == request else { return }
            timedOutRequestID = request
            switchTask?.cancel()
            // Keep the switch locked until the native operation and any owned
            // member cleanup actually return, even after the UI deadline.
            setFeedback(String(localized: "audio.target_switch_unconfirmed", defaultValue: "Could not confirm the switch to \(device.name). Check the device and try again."), kind: .failure,
                        presentation: .unconfirmed, clearWhenSelected: device.id)
            completeSelection(selection, .failed(feedback))
            refresh()
        }
        let serviceLease = hardware.serviceEpoch?.capture()
        switchTask = Task { [weak self] in
            await AudioServiceOperation.$lease.withValue(serviceLease) { [weak self] in
                guard let self else { return }
                defer {
                    if requestID == request {
                        let didTimeOut = timedOutRequestID == request
                        requestID = nil
                        timedOutRequestID = nil
                        timeoutTask?.cancel()
                        timeoutTask = nil
                        isSwitching = false
                        switchTask = nil
                        if didTimeOut, feedbackKind == .progress {
                            setFeedback(ordinaryFeedback, kind: .neutral)
                        }
                        completeSelection(selection, .ignored)
                        onInteractionChange?(.switching, false)
                        if didTimeOut || needsRefresh { refresh() }
                    }
                }
                logger.info("Switch requested; backend=\(String(describing: device.transport), privacy: .public)")
                var selectionSubmitted = false
                do {
                    try Task.checkCancellation()
                    guard !shuttingDown else { throw CancellationError() }
                    await drainInteractions?()
                    try Task.checkCancellation()
                    guard !shuttingDown else { throw CancellationError() }
                    let deadline = ContinuousClock.now.advanced(by: timeout)
                    if needsCurrentSelectionCheck {
                        guard try await loadSnapshot(forSwitch: request, refreshRoutes: true) else {
                            throw CancellationError()
                        }
                        guard requestID == request, timedOutRequestID != request else { return }
                        if currentDeviceID == device.id {
                            // Fresh identity can retire this target's old warning;
                            // it does not change the previous request's outcome.
                            dismissConfirmedFailure()
                            completeSelection(selection, .alreadySelected)
                            return
                        }
                        guard let current = devices.first(where: { $0.id == device.id }), current.isAvailable else {
                            throw AudioServiceError.unavailable(String(localized: "audio.device_unavailable", defaultValue: "The device is unavailable. Try again later."))
                        }
                        confirmedTargetID = nil
                        setFeedback(String(localized: "audio.switching_to", defaultValue: "Switching to \(device.name)…"), kind: .progress)
                    }
                    try await deviceStrategies.select(device, isShuttingDown: { shuttingDown })
                    selectionSubmitted = true
                    try Task.checkCancellation()
                    guard requestID == request, timedOutRequestID != request else { return }
                    while !Task.isCancelled {
                        try await loadSnapshot(forSwitch: request)
                        guard requestID == request, timedOutRequestID != request else { return }
                        if currentDeviceID == device.id {
                            confirmedTargetID = device.id
                            setFeedback(String(localized: "audio.switched_to", defaultValue: "Switched to \(devices.first(where: { $0.id == device.id })?.name ?? device.name)"), kind: .success)
                            completeSelection(selection, .selected)
                            logger.info("Switch confirmed by system readback")
                            return
                        }
                        guard ContinuousClock.now < deadline else {
                            throw AudioServiceError.unavailable(String(localized: "audio.target_switch_unconfirmed", defaultValue: "Could not confirm the switch to \(device.name). Check the device and try again."))
                        }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, !shuttingDown, requestID == request, timedOutRequestID != request else { return }
                    // Best-effort refresh keeps the selected row tied to the real system result.
                    let reconciled = (try? await loadSnapshot(forSwitch: request)) == true
                    guard requestID == request, timedOutRequestID != request else { return }
                    let presentation: FeedbackPresentation
                    // A backend can submit and then exhaust its own readback
                    // deadline before the strategy returns. Preserve that typed
                    // uncertainty instead of treating the throw as a refusal.
                    let backendUnconfirmed = if case AudioServiceError.selectionUnconfirmed = error { true } else { false }
                    if !reconciled || selectionSubmitted || backendUnconfirmed {
                        presentation = .unconfirmed
                    } else if currentDeviceID == device.id {
                        // The output reached the target, but the strategy's leave
                        // cleanup did not complete. Preserve that failure without
                        // contradicting the fresh system readback.
                        presentation = .incomplete
                    } else {
                        presentation = .targetFailure(device.name)
                    }
                    let failureTargetID: String? = if case .incomplete = presentation { nil } else { device.id }
                    setFeedback(error.localizedDescription, kind: .failure,
                                presentation: presentation, clearWhenSelected: failureTargetID)
                    completeSelection(selection, .failed(error.localizedDescription))
                    logger.error("Switch not confirmed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func completeSelection(_ request: AudioSelectionRequest, _ outcome: AudioSelectionOutcome) {
        guard selectionRequest == request else { return }
        selectionRequest = nil
        onSelectionResult?(AudioSelectionResult(request: request, outcome: outcome))
    }

    /// Refresh identity on the owning executors immediately before an explicit
    /// volume request. This does not select, connect, or reconcile a route.
    func resolveVolumeTarget(deviceID: String) async throws -> AudioVolumeTarget {
        guard !shuttingDown, !isSwitching, !isPreparingToQuit, recoveryGeneration == nil else { throw AudioVolumeIssue.paused }
        let serviceLease = try AudioServiceOperation.capture(from: hardware.serviceEpoch)
        guard let expected = volumeTargets[deviceID] else { throw AudioVolumeIssue.identityUnconfirmed }
        snapshotSerial += 1
        let serial = snapshotSerial
        let hal: CoreAudioSnapshot
        do { hal = try await hardware.snapshot() }
        catch {
            if !Task.isCancelled, !shuttingDown, !isSwitching, !isPreparingToQuit,
               serial >= appliedSnapshotSerial {
                appliedSnapshotSerial = serial
                publishFailedDiscoveryRead()
            }
            throw error
        }
        try Task.checkCancellation()
        let route: PrivateRouteSnapshot
        if expected.receiverID != nil { route = await routes.freshSnapshot() }
        else { route = routes.snapshot() }
        try Task.checkCancellation()
        guard !shuttingDown, !isSwitching, !isPreparingToQuit, recoveryGeneration == nil else { throw AudioVolumeIssue.paused }
        // A newer catalog (including another row) supersedes this whole read.
        // Do not publish stale identity or invalidate a newer request first.
        guard serial >= appliedSnapshotSerial, volumeTargets[deviceID] == expected else {
            throw AudioVolumeIssue.identityChanged
        }
        try serviceLease?.check()
        try validateServiceGeneration(hal)
        appliedSnapshotSerial = serial
        publishSnapshot(hal: hal, route: route)
        guard volumeTargets[deviceID] == expected else { throw AudioVolumeIssue.identityChanged }
        return expected
    }

    private func updateVolumeProjection(hal: CoreAudioSnapshot, routes: PrivateRouteSnapshot, devices: [AudioDevice]) {
        var nextIdentities: [String: AudioVolumeIdentity] = [:]
        var targets: [String: AudioVolumeTarget] = [:]
        var bindings: [AudioVolumeBinding] = []
        for device in devices {
            guard let identity = AudioVolumeIdentity.resolve(device, hal: hal, routes: routes) else {
                bindings.append(AudioVolumeBinding(deviceID: device.id, target: nil,
                    unavailableReason: AudioVolumeIdentity.unavailableReason(device, routes: routes)))
                continue
            }
            nextIdentities[device.id] = identity
            let target: AudioVolumeTarget
            if volumeIdentities[device.id] == identity, let current = volumeTargets[device.id], current.serviceGeneration == hal.serviceGeneration { target = current }
            else {
                target = AudioVolumeTarget(deviceID: device.id, uid: identity.uid,
                                           receiverID: identity.receiverID, generation: UUID(), serviceGeneration: hal.serviceGeneration)
            }
            targets[device.id] = target
            bindings.append(AudioVolumeBinding(deviceID: device.id, target: target))
        }
        volumeIdentities = nextIdentities
        volumeTargets = targets
        volumeBindings = bindings
    }

    private func setFeedback(_ message: String, kind: FeedbackKind,
                             presentation: FeedbackPresentation = .ordinary,
                             clearWhenSelected targetID: String? = nil) {
        cancelFeedbackExpiry()
        // User actions supersede a temporary catalog error. A later successful
        // background read must not restore feedback from before that action.
        feedbackBeforeCatalogReadFailure = nil
        feedback = message
        feedbackKind = kind
        feedbackPresentation = presentation
        if kind == .failure {
            failureEvent = PresentationFailure(message: presentationFeedback)
            let failure = TransientFailure(targetID: targetID)
            transientFailure = failure
            feedbackExpiryTask = Task { [weak self, failureFeedbackDuration] in
                do { try await Task.sleep(for: failureFeedbackDuration) } catch { return }
                self?.dismissTransientFailure(id: failure.id)
            }
        }
    }

    private var ordinaryFeedback: String {
        devices.isEmpty ? String(localized: "audio.no_devices", defaultValue: "No available sound output devices found.") : String(localized: "audio.click_to_switch", defaultValue: "Click a device to switch output")
    }

    private func cancelFeedbackExpiry() {
        feedbackExpiryTask?.cancel()
        feedbackExpiryTask = nil
        transientFailure = nil
    }

    private func dismissConfirmedFailure() {
        guard let failure = transientFailure, let targetID = failure.targetID,
              currentDeviceID == targetID else { return }
        dismissTransientFailure(id: failure.id)
    }

    private func dismissTransientFailure(id: UUID) {
        guard !shuttingDown, transientFailure?.id == id else { return }
        cancelFeedbackExpiry()
        if feedbackBeforeCatalogReadFailure != nil {
            // A current read fault stays visible, but recovering that read must
            // not resurrect the expired operation warning it temporarily hid.
            feedbackBeforeCatalogReadFailure = (ordinaryFeedback, .neutral, .ordinary)
        } else {
            // The UI deadline does not cancel a native action. Keep indicating
            // its drain until the original task actually releases the boundary.
            let awaitingReturn = isSwitching && timedOutRequestID != nil && timedOutRequestID == requestID
            feedback = awaitingReturn ? String(localized: "audio.waiting_for_switch", defaultValue: "Still waiting for switching to finish…") : ordinaryFeedback
            feedbackKind = awaitingReturn ? .progress : .neutral
            feedbackPresentation = .ordinary
        }
    }

    @discardableResult
    private func loadSnapshot(forSwitch request: UUID? = nil, refreshRoutes: Bool = false) async throws -> Bool {
        try Task.checkCancellation()
        let serviceLease = try AudioServiceOperation.capture(from: hardware.serviceEpoch)
        guard !shuttingDown else { throw CancellationError() }
        // A choice already in progress must still confirm its readback because
        // prepareToQuit waits for that transaction before inspecting ownership.
        guard request != nil || !isPreparingToQuit else { needsRefresh = true; return false }
        snapshotSerial += 1
        let serial = snapshotSerial
        let readEpoch = backgroundReadEpoch
        isRefreshing = true
        defer { isRefreshing = false }
        let freshRoute: PrivateRouteSnapshot?
        if refreshRoutes || recoveryGeneration != nil {
            // Read the private worker first, then HAL: a slow worker must not
            // make an earlier default-output read appear fresh at completion.
            freshRoute = await routes.freshSnapshot()
            try Task.checkCancellation()
            guard !shuttingDown else { throw CancellationError() }
            guard request != nil || (!isPreparingToQuit && readEpoch == backgroundReadEpoch) else {
                needsRefresh = true
                return false
            }
            guard !isSwitching || request == requestID else { return false }
            guard serial >= appliedSnapshotSerial else { return false }
        } else {
            freshRoute = nil
        }
        let hal: CoreAudioSnapshot
        do { hal = try await hardware.snapshot() }
        catch {
            guard request != nil || (!isPreparingToQuit && readEpoch == backgroundReadEpoch) else {
                needsRefresh = true
                return false
            }
            guard !isSwitching || request == requestID else { return false }
            guard serial >= appliedSnapshotSerial else { return false }
            guard !Task.isCancelled, !shuttingDown else { throw CancellationError() }
            appliedSnapshotSerial = serial
            publishFailedDiscoveryRead()
            throw SnapshotFailure(serial: serial, underlying: error)
        }
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        guard request != nil || (!isPreparingToQuit && readEpoch == backgroundReadEpoch) else {
            needsRefresh = true
            return false
        }
        guard !isSwitching || request == requestID else { return false }
        guard serial >= appliedSnapshotSerial else { return false }
        let route = freshRoute ?? routes.snapshot()
        try serviceLease?.check()
        try validateServiceGeneration(hal)
        appliedSnapshotSerial = serial
        publishSnapshot(hal: hal, route: route)
        if recoveryGeneration != nil {
            recoveryGeneration = nil
            onServiceRecoveryChange?(false)
        }
        return true
    }

    private func validateServiceGeneration(_ snapshot: CoreAudioSnapshot) throws {
        guard let generation = hardware.serviceEpoch?.capture().id else { return }
        guard snapshot.serviceGeneration == generation else { throw AudioServiceResetError.serviceChanged }
    }

    private func publishSnapshot(hal: CoreAudioSnapshot, route: PrivateRouteSnapshot) {
        lastCatalogReadFailure = nil
        lastHardwareSnapshot = hal
        lastRouteSnapshot = route
        discoveryInventory = AudioDiscoveryInventory.merge(hal: hal, routes: route)
        let catalog = AudioCatalog.merge(hal: hal, routes: route)
            .preservingUnconfirmedDevices(from: devices, discovery: discoveryInventory)
        devices = catalog.devices
        currentDeviceID = catalog.currentDeviceID
        updateVolumeProjection(hal: hal, routes: route, devices: catalog.devices)
        onCatalogChange?(devices, volumeBindings)
        let warnings = hal.warnings + [route.warning, observerWarning, catalog.warning].compactMap { $0 }
        catalogWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")

        guard !isSwitching else { return }
        if let previous = feedbackBeforeCatalogReadFailure {
            feedbackBeforeCatalogReadFailure = nil
            feedback = previous.message
            feedbackKind = previous.kind
            feedbackPresentation = previous.presentation
        }
        dismissConfirmedFailure()
        if let confirmedTargetID, confirmedTargetID != currentDeviceID {
            self.confirmedTargetID = nil
            if feedbackKind == .success { feedbackKind = .neutral }
        }
        if feedbackKind == .neutral {
            feedback = ordinaryFeedback
        }
    }

    private func publishFailedDiscoveryRead() {
        // A failed fresh read revokes every previous absence conclusion, even
        // when it occurred during selection/volume identity confirmation.
        discoveryInventory = .unconfirmed
        devices = devices.map {
            var item = $0
            item.isAvailable = false
            item.unavailableReason = String(localized: "audio.directory_failed", defaultValue: "The device list could not be read. Try again later.")
            item.shortcutTarget = nil
            return item
        }
        volumeTargets = [:]
        volumeIdentities = [:]
        volumeBindings = devices.map { AudioVolumeBinding(deviceID: $0.id, target: nil) }
        currentDeviceID = nil
        onCatalogChange?(devices, volumeBindings)
    }
}

private struct SnapshotFailure: LocalizedError {
    let serial: Int
    let underlying: any Error
    var errorDescription: String? { underlying.localizedDescription }
}
