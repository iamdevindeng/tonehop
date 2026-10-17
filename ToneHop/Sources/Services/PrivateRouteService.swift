import Foundation

struct PrivateAudioRoute: Sendable, Equatable {
    let identifier: String
    let name: String
    let uid: String?
    let isSelected: Bool
    let transportKind: PrivateRouteTransport
    let selectionCapability: PrivateRouteSelectionCapability
    var unavailableReason: String? = nil
    var icon: AudioDeviceIcon = .fallback

    var canSelect: Bool { selectionCapability != .unavailable }
    var transport: String { transportKind.rawValue }

    init(identifier: String, name: String, uid: String?, isSelected: Bool,
         transportKind: PrivateRouteTransport, selectionCapability: PrivateRouteSelectionCapability,
         unavailableReason: String? = nil, icon: AudioDeviceIcon = .fallback) {
        self.identifier = identifier
        self.name = name
        self.uid = uid
        self.isSelected = isSelected
        self.transportKind = transportKind
        self.selectionCapability = selectionCapability
        self.unavailableReason = unavailableReason
        self.icon = icon
    }

    /// Compatibility for existing catalog fixtures and bridge fields. The
    /// interpretation matches the previous worker dispatch exactly; unknown
    /// classification alone never grants capability.
    init(identifier: String, name: String, uid: String?, isSelected: Bool, canSelect: Bool,
         transport: String, unavailableReason: String? = nil, icon: AudioDeviceIcon = .fallback) {
        self.init(identifier: identifier, name: name, uid: uid, isSelected: isSelected,
                  transportKind: PrivateRouteTransport(rawValue: transport),
                  selectionCapability: canSelect ? (transport == "airplay" ? .retainedAirPlay : .avSystemRoute) : .unavailable,
                  unavailableReason: unavailableReason, icon: icon)
    }
}

struct PrivateRouteSnapshot: Sendable, Equatable {
    let routes: [PrivateAudioRoute]
    let warning: String?
    let diagnostics: String
    var systemRouteMemberComparison: SystemRouteMemberComparison? = nil
    var sourceHealth: PrivateRouteSourceHealth? = nil
    var selectedVolumeAssociation: SystemRouteVolumeAssociation? = nil
    var confirmedShortcutIdentifiers: Set<String> = []
    var discovery: AudioDiscoverySourceInventory = .unconfirmed
}

/// Value-only boundary also used to exercise the deferred-failure lifecycle
/// without launching discovery or touching the system's audio route.
protocol PrivateRouteWorking: Sendable {
    func read() async -> PrivateRouteSnapshot
    func reconcileRuntimeState() async throws
    func submit(identifier: String) async throws
    func prepareToLeave() async throws
    func completedLeave() async throws
    func finishFailedSelection() async throws
    func ownedStreamForExit() async throws -> OwnedRouteExitEvidence?
    func stop() async throws
}

extension PrivateRouteWorking {
    func reconcileRuntimeState() async throws {}
    func ownedStreamForExit() async throws -> OwnedRouteExitEvidence? {
        throw AudioServiceError.unavailable(String(localized: "audio.exit_check_unsupported", defaultValue: "The current audio service does not support checking cleanup before quitting."))
    }
}

/// Owns all Objective-C state on one executor. The UI only receives value snapshots.
private actor PrivateRouteWorker: PrivateRouteWorking {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        AudioRouteExecutor.shared.asUnownedSerialExecutor()
    }
    // Lazy initialization occurs in the first actor job on the audio thread.
    private lazy var bridge = THPrivateAudioBridge(performIfRunning: { [shutdownSignal] in
        shutdownSignal.performIfRunning(servicePermit: AudioServiceOperation.lease?.permit, $0)
    })
    private lazy var endpoints = THPrivateEndpointBridge(performIfRunning: { [shutdownSignal] in
        shutdownSignal.performIfRunning(servicePermit: AudioServiceOperation.lease?.permit, $0)
    })
    private lazy var systemSelection = THSystemAudioSnapshotBridge()
    private lazy var retained = THRetainedSystemAudioBridge(endpointDiscovery: endpoints)
    private let shutdownSignal: AudioShutdownSignal
    private var stopped = false

    init(shutdownSignal: AudioShutdownSignal) { self.shutdownSignal = shutdownSignal }

    private var stoppedSnapshot: PrivateRouteSnapshot {
        PrivateRouteSnapshot(routes: [], warning: nil, diagnostics: "Audio route discovery stopped")
    }

    func read() -> PrivateRouteSnapshot {
        guard !shutdownSignal.isShuttingDown else { return stoppedSnapshot }
        // Keep the scoped AV session and the existing raw Detailed discovery
        // needed for endpoint access. Raw shutdown only releases its reference;
        // the AV session withdraws this client's scoped discovery request.
        let av: AVRouteDiscoveryEvidence
        do {
            av = PrivateRouteSnapshotAdapter.avDiscovery(try bridge.snapshot())
        } catch {
            av = .failed(error)
        }
        guard !shutdownSignal.isShuttingDown else { return stoppedSnapshot }
        let endpointEvidence: EndpointDiscoveryEvidence
        do {
            endpointEvidence = PrivateRouteSnapshotAdapter.endpointDiscovery(try endpoints.snapshot())
        } catch {
            endpointEvidence = .failed(error)
        }
        guard !shutdownSignal.isShuttingDown else { return stoppedSnapshot }
        let selectionEvidence: SystemSelectionEvidence
        do {
            selectionEvidence = PrivateRouteSnapshotAdapter.systemSelection(try systemSelection.snapshot())
        } catch {
            selectionEvidence = .failed(error)
        }
        guard !shutdownSignal.isShuttingDown else { return stoppedSnapshot }
        let retainedEvidence: RetainedSystemRouteEvidence
        do {
            retainedEvidence = PrivateRouteSnapshotAdapter.retainedSystemRoute(
                try retained.snapshot(isShuttingDown: { [shutdownSignal] in shutdownSignal.isShuttingDown })
            )
        } catch {
            retainedEvidence = .failed(error)
        }
        guard !shutdownSignal.isShuttingDown else { return stoppedSnapshot }
        return PrivateRouteCatalog.merge(av: av, endpoints: endpointEvidence,
                                         selection: selectionEvidence, retained: retainedEvidence)
    }

    func submit(identifier: String) throws {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        let current = read()
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        guard let route = current.routes.first(where: { $0.identifier == identifier }), route.canSelect else {
            throw AudioServiceError.unavailable(current.routes.first(where: { $0.identifier == identifier })?.unavailableReason ?? String(localized: "audio.no_reusable_route", defaultValue: "This device has no reusable system route right now."))
        }
        switch route.selectionCapability {
        case .retainedAirPlay, .existingSystemStream:
            try retained.select(identifier: identifier, isCancelled: { Task.isCancelled },
                                isShuttingDown: { [shutdownSignal] in shutdownSignal.isShuttingDown },
                                performIfRunning: { [shutdownSignal] in shutdownSignal.performIfRunning(servicePermit: AudioServiceOperation.lease?.permit, $0) })
        case .avSystemRoute:
            try bridge.select(identifier: identifier, isCancelled: { [shutdownSignal] in
                Task.isCancelled || shutdownSignal.isShuttingDown
            }, performIfRunning: { [shutdownSignal] in shutdownSignal.performIfRunning(servicePermit: AudioServiceOperation.lease?.permit, $0) })
        case .unavailable:
            throw AudioServiceError.unavailable(route.unavailableReason ?? String(localized: "audio.no_reusable_route", defaultValue: "This device has no reusable system route right now."))
        }
    }

    func prepareToLeave() throws {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        try retained.prepareToLeave()
    }

    func ownedStreamForExit() throws -> OwnedRouteExitEvidence? {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        let snapshot = try retained.ownedStreamForExit()
        guard !(snapshot["ownedStream"] is NSNull) else { return nil }
        guard let stream = snapshot["ownedStream"] as? [String: Any],
              let receiverID = stream["receiverID"] as? String, !receiverID.isEmpty,
              let uid = stream["streamUID"] as? String, !uid.isEmpty,
              let name = stream["name"] as? String, !name.isEmpty else {
            throw AudioServiceError.unavailable(String(localized: "audio.exit_stream_identity_incomplete", defaultValue: "The previous audio stream could not be fully identified. The app did not quit."))
        }
        return OwnedRouteExitEvidence(receiverID: receiverID, streamUID: uid, name: name)
    }

    func reconcileRuntimeState() throws {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        try retained.reconcileRuntimeState(isShuttingDown: { [shutdownSignal] in shutdownSignal.isShuttingDown },
                                           performIfRunning: { [shutdownSignal] in shutdownSignal.performIfRunning(servicePermit: AudioServiceOperation.lease?.permit, $0) })
    }

    func completedLeave() throws {
        try shutdownSignal.checkRunning()
        try retained.completedLeave(isShuttingDown: { [shutdownSignal] in shutdownSignal.isShuttingDown },
                                    performIfRunning: { [shutdownSignal] in shutdownSignal.performIfRunning(servicePermit: AudioServiceOperation.lease?.permit, $0) })
    }

    func finishFailedSelection() throws {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        try retained.finishFailedSelection(isShuttingDown: { [shutdownSignal] in shutdownSignal.isShuttingDown },
                                           performIfRunning: { [shutdownSignal] in shutdownSignal.performIfRunning(servicePermit: AudioServiceOperation.lease?.permit, $0) })
    }

    func stop() throws {
        guard !stopped else { return }
        stopped = true
        // These sessions belong to the App. Stop them even if one bridge reports
        // an internal release error; output selection is never part of shutdown.
        defer {
            endpoints.stop()
            bridge.stop()
        }
        try retained.shutdown()
    }
}

@MainActor
final class PrivateRouteService {
    var onChange: (() -> Void)?
    private let shutdownSignal: AudioShutdownSignal
    private let worker: any PrivateRouteWorking
    private var serviceEpoch: AudioServiceEpoch?
    private var latestServiceGeneration: UUID?
    private let cleanupRetryDelay: Duration
    private let runtimePollDelay: Duration
    private var monitor: Task<Void, Never>?
    private var runtimeTask: Task<Void, Never>?
    private var needsRuntimeReconcile = false
    private struct FailedSelectionCleanupRequest {
        let id: UUID
        let lease: AudioServiceEpoch.Lease?
    }
    private var failedSelectionCleanupTask: Task<Void, Never>?
    private var failedSelectionRequest: FailedSelectionCleanupRequest?
    private var shutdownTask: Task<Void, any Error>?
    private var latest = PrivateRouteSnapshot(routes: [], warning: nil, diagnostics: "AVRouting: awaiting first sample")
    private var generation = 0
    private var snapshotSerial = 0
    private var appliedSnapshotSerial = 0
    init() {
        let signal = AudioShutdownSignal()
        shutdownSignal = signal
        worker = PrivateRouteWorker(shutdownSignal: signal)
        cleanupRetryDelay = .seconds(1)
        runtimePollDelay = .seconds(3)
    }

    init(worker: any PrivateRouteWorking, shutdownSignal: AudioShutdownSignal,
         cleanupRetryDelay: Duration = .seconds(1), runtimePollDelay: Duration = .seconds(3)) {
        self.worker = worker
        self.shutdownSignal = shutdownSignal
        self.cleanupRetryDelay = cleanupRetryDelay
        self.runtimePollDelay = runtimePollDelay
    }

    func bindServiceEpoch(_ epoch: AudioServiceEpoch?) {
        serviceEpoch = epoch
        latestServiceGeneration = epoch?.capture().id
    }

    func serviceDidRestart() {
        // Invalidate only published evidence. Native ownership is deliberately
        // retained for its existing live-evidence reconciliation rules.
        latest = PrivateRouteSnapshot(routes: [], warning: nil, diagnostics: "Audio service reset; awaiting fresh evidence")
        latestServiceGeneration = serviceEpoch?.capture().id
        snapshotSerial += 1
        appliedSnapshotSerial = snapshotSerial
    }

    private func performWorker<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        let lease = try AudioServiceOperation.capture(from: serviceEpoch)
        return try await AudioServiceOperation.$lease.withValue(lease) {
            let result = try await operation()
            try lease?.check()
            return result
        }
    }

    func snapshot() -> PrivateRouteSnapshot {
        guard latestServiceGeneration == serviceEpoch?.capture().id else {
            return PrivateRouteSnapshot(routes: [], warning: nil, diagnostics: "Audio service reset; awaiting fresh evidence")
        }
        return latest
    }

    /// Refresh on the existing worker; does not select or create a route.
    func freshSnapshot() async -> PrivateRouteSnapshot { await readAndPublish() }

    func start() {
        guard monitor == nil, !shutdownSignal.isShuttingDown else { return }
        monitor = Task { [weak self, runtimePollDelay] in
            while !Task.isCancelled {
                self?.systemOutputDidChange()
                do { try await Task.sleep(for: runtimePollDelay) }
                catch { return }
            }
        }
    }

    /// Both HAL notifications and the fallback poll enter the AirPlay strategy's
    /// lifecycle here. A display snapshot stays read-only. The native worker
    /// rechecks live identity/output before it may remove this App's old member;
    /// this event never replays the user's system selection or submits an Add.
    func systemOutputDidChange() {
        guard !shutdownSignal.isShuttingDown else { return }
        needsRuntimeReconcile = true
        guard runtimeTask == nil else { return }
        let currentGeneration = generation
        runtimeTask = Task { [weak self, worker, shutdownSignal, cleanupRetryDelay] in
            defer { self?.runtimeTask = nil }
            while !Task.isCancelled, !shutdownSignal.isShuttingDown {
                guard let self, generation == currentGeneration else { return }
                needsRuntimeReconcile = false
                var retryCallback = false
                do { try await performWorker { try await worker.reconcileRuntimeState() } }
                catch is CancellationError { return }
                catch {
                    retryCallback = RetainedRouteFailure(error) == .pending
                    // Background cleanup failures are operational diagnostics,
                    // including a failed quit's later reconciliation. Display
                    // only the source/capability warnings from the actual read.
                    if !retryCallback {
                        NSLog("Background route reconciliation did not complete: %@", error.localizedDescription)
                    }
                }
                guard !Task.isCancelled, !shutdownSignal.isShuttingDown else { return }
                _ = await readAndPublish()
                guard !Task.isCancelled, !shutdownSignal.isShuttingDown, generation == currentGeneration else { return }
                // Collapse a burst to one follow-up pass, but retain events
                // arriving while the native operation or snapshot is running.
                if needsRuntimeReconcile { continue }
                guard retryCallback else { return }
                do { try await Task.sleep(for: cleanupRetryDelay) }
                catch { return }
            }
        }
    }

    func refresh() {
        guard !shutdownSignal.isShuttingDown else { return }
        Task { [weak self] in _ = await self?.readAndPublish() }
    }

    func select(identifier: String) async throws {
        let lease = try AudioServiceOperation.capture(from: serviceEpoch)
        try await AudioServiceOperation.$lease.withValue(lease) {
            try await selectInCurrentService(identifier: identifier)
            try lease?.check()
        }
    }

    private func selectInCurrentService(identifier: String) async throws {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        let currentGeneration = generation
        let requestID = UUID()
        do { try await performWorker { try await worker.submit(identifier: identifier) } }
        catch {
            // A failed native request may have created a stream, rolled back, or
            // invalidated the retained capability. Publish that real state first.
            if !shutdownSignal.isShuttingDown {
                resumeFailedSelectionCleanup(for: requestID)
                _ = await readAndPublish()
            }
            let native = error as NSError
            if native.domain == THRetainedAudioErrorDomain,
               native.code == THRetainedAudioError.capturedSelectionUnconfirmed.rawValue {
                // The native bridge already submitted the HAL request. Missing
                // strict receiver readback is an unknown result, not a refusal.
                throw AudioServiceError.selectionUnconfirmed(native.localizedDescription)
            }
            throw error
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try AudioServiceOperation.lease?.check()
            try shutdownSignal.checkRunning()
            guard generation == currentGeneration else { throw CancellationError() }
            let next = await readAndPublish()
            try Task.checkCancellation()
            try AudioServiceOperation.lease?.check()
            guard generation == currentGeneration else { throw CancellationError() }
            if next.routes.contains(where: { $0.identifier == identifier && $0.isSelected }) { return }
            try await Task.sleep(for: .milliseconds(350))
        }
        throw AudioServiceError.selectionUnconfirmed(String(localized: "audio.airplay_switch_timeout", defaultValue: "AirPlay switching timed out. The system did not confirm the target device."))
    }

    func prepareToLeave() async throws {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        try await performWorker { try await worker.prepareToLeave() }
    }

    func ownedStreamForExit() async throws -> OwnedRouteExitEvidence? {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        return try await performWorker { try await worker.ownedStreamForExit() }
    }

    func completedLeave() async throws {
        try shutdownSignal.checkRunning()
        do { try await performWorker { try await worker.completedLeave() } }
        catch {
            if !shutdownSignal.isShuttingDown {
                _ = await readAndPublish()
            }
            throw error
        }
        try shutdownSignal.checkRunning()
        _ = await readAndPublish()
    }

    func beginShutdown() {
        guard !shutdownSignal.isShuttingDown else { return }
        shutdownSignal.begin()
        cancelMonitoring()
        onChange = nil
    }

    func shutdown() async throws {
        beginShutdown()
        if let shutdownTask { return try await shutdownTask.value }
        let runtime = runtimeTask
        let task = Task { [worker, shutdownSignal] in
            await runtime?.value
            await shutdownSignal.drainSubmissions()
            try await worker.stop()
        }
        shutdownTask = task
        try await task.value
    }

    func stop() {
        beginShutdown()
        Task {
            do { try await shutdown() }
            catch { NSLog("Retained route cleanup failed: %@", error.localizedDescription) }
        }
    }

    private func resumeFailedSelectionCleanup(for requestID: UUID) {
        failedSelectionRequest = FailedSelectionCleanupRequest(id: requestID, lease: AudioServiceOperation.lease)
        guard failedSelectionCleanupTask == nil else { return }
        failedSelectionCleanupTask = Task { [weak self, worker, shutdownSignal, cleanupRetryDelay] in
            defer { self?.failedSelectionCleanupTask = nil }
            while !Task.isCancelled, !shutdownSignal.isShuttingDown {
                guard let attemptedRequest = self?.failedSelectionRequest else { return }
                // One task may outlive several requests. Each pass keeps the
                // originating request's lease, including a revoked old lease;
                // it must not inherit the first request or adopt a fresh one.
                let retryCallback = await AudioServiceOperation.$lease.withValue(attemptedRequest.lease) { [weak self] in
                    var retryCallback = false
                    do {
                        try await self?.performWorker { try await worker.finishFailedSelection() }
                    } catch {
                        // Only an outstanding callback may retry. Invalid identity,
                        // failed Remove, or changed system output ends this task;
                        // native state stays unavailable and the original failure
                        // feedback remains visible. No new Add is ever submitted.
                        retryCallback = RetainedRouteFailure(error) == .pending
                    }
                    guard !Task.isCancelled, !shutdownSignal.isShuttingDown else { return false }
                    _ = await self?.readAndPublish()
                    return retryCallback
                }
                guard !Task.isCancelled, !shutdownSignal.isShuttingDown else { return }
                // A second failed request may have arrived while this attempt
                // awaited its actor. Keep one task, but do not lose its cleanup.
                if self?.failedSelectionRequest?.id != attemptedRequest.id { continue }
                guard retryCallback else {
                    self?.failedSelectionRequest = nil
                    return
                }
                do { try await Task.sleep(for: cleanupRetryDelay) }
                catch { return }
            }
        }
    }

    private func cancelMonitoring() {
        generation += 1
        monitor?.cancel()
        monitor = nil
        runtimeTask?.cancel()
        needsRuntimeReconcile = false
        failedSelectionCleanupTask?.cancel()
        failedSelectionRequest = nil
    }

    /// All snapshot producers share ordering. A slow older read must not
    /// overwrite a newer runtime result within the same running generation.
    private func readAndPublish() async -> PrivateRouteSnapshot {
        guard !shutdownSignal.isShuttingDown else { return snapshot() }
        snapshotSerial += 1
        let serial = snapshotSerial
        let currentGeneration = generation
        let serviceGeneration = serviceEpoch?.capture().id
        guard let snapshot = try? await performWorker({ await worker.read() }) else { return self.snapshot() }
        guard !shutdownSignal.isShuttingDown, generation == currentGeneration,
              serial >= appliedSnapshotSerial,
              serviceGeneration == serviceEpoch?.capture().id else { return self.snapshot() }
        appliedSnapshotSerial = serial
        latestServiceGeneration = serviceGeneration
        publish(snapshot)
        return snapshot
    }

    private func publish(_ snapshot: PrivateRouteSnapshot) {
        guard !shutdownSignal.isShuttingDown, latest != snapshot else { return }
        latest = snapshot
        onChange?()
    }
}
