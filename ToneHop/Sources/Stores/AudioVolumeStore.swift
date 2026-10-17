import Foundation
import Observation

/// Coordinates display and requests only. Identity and HAL capability decisions
/// belong to the catalog projection and the injected volume provider.
@MainActor @Observable
final class AudioVolumeStore {
    private(set) var rows: [String: AudioVolumeRowState] = [:]
    private(set) var isPaused = false
    private(set) var isClosed = false
    private(set) var observationIssue: AudioVolumeIssue?
    private(set) var failureEvent: PresentationFailure?

    @ObservationIgnored private let provider: any AudioVolumeProviding
    @ObservationIgnored private let resolveTarget: @MainActor (String) async throws -> AudioVolumeTarget
    @ObservationIgnored private let throttle: Duration
    @ObservationIgnored private let pollingInterval: Duration
    @ObservationIgnored private var bindings: [AudioVolumeBinding] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var writers: [String: UUID] = [:]
    @ObservationIgnored private var activeRequests = Set<String>()
    @ObservationIgnored private var permits: [String: AudioMutationPermit] = [:]
    @ObservationIgnored private var readers: [String: UUID] = [:]
    @ObservationIgnored private var pending: [String: Request] = [:]
    @ObservationIgnored private var latestSequence: [String: UInt64] = [:]
    @ObservationIgnored private var editing = Set<String>()
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var observationID: UUID?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var lastSubmission: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var delivery: AudioChangeDelivery?
    @ObservationIgnored private var operationIssues: [String: AudioVolumeIssue] = [:]
    @ObservationIgnored private var readFailures: [AudioVolumeTarget: AudioVolumeIssue] = [:]

    private struct Request {
        let target: AudioVolumeTarget
        let value: Float
        let sequence: UInt64
        let isFinal: Bool
        let permit: AudioMutationPermit
    }

    init(provider: any AudioVolumeProviding,
         resolveTarget: @escaping @MainActor (String) async throws -> AudioVolumeTarget,
         throttle: Duration = .milliseconds(50),
         pollingInterval: Duration = .seconds(2)) {
        self.provider = provider
        self.resolveTarget = resolveTarget
        self.throttle = throttle
        self.pollingInterval = pollingInterval
    }

    func state(for deviceID: String) -> AudioVolumeRowState? { rows[deviceID] }

    func updateTargets(_ targets: [String: AudioVolumeTarget]) {
        updateBindings(targets.map { AudioVolumeBinding(deviceID: $0.key, target: $0.value) })
    }

    func updateBindings(_ newBindings: [AudioVolumeBinding]) {
        guard !isClosed else { return }
        let grouped = Dictionary(grouping: newBindings, by: \.deviceID)
        let safeBindings = grouped.keys.sorted().compactMap { id -> AudioVolumeBinding? in
            guard !id.isEmpty, let matches = grouped[id], let first = matches.first else { return nil }
            guard matches.count == 1, first.target == nil ||
                    (first.target?.deviceID == id && first.target?.uid.isEmpty == false) else {
                return AudioVolumeBinding(deviceID: id, target: nil, unavailableReason: .identityUnconfirmed)
            }
            return first
        }
        guard safeBindings != bindings else { return }
        bindings = safeBindings
        var next: [String: AudioVolumeRowState] = [:]
        for binding in safeBindings {
            if let previous = rows[binding.deviceID], previous.target == binding.target, binding.target != nil {
                next[binding.deviceID] = previous
            } else {
                invalidate(binding.deviceID)
                operationIssues[binding.deviceID] = nil
                readFailures = readFailures.filter { $0.key.deviceID != binding.deviceID }
                next[binding.deviceID] = AudioVolumeRowState(deviceID: binding.deviceID, target: binding.target,
                    issue: binding.target == nil ? binding.unavailableReason : nil)
            }
        }
        for id in rows.keys where next[id] == nil {
            invalidate(id)
            operationIssues[id] = nil
            readFailures = readFailures.filter { $0.key.deviceID != id }
        }
        rows = next
        guard !isPaused else { return }
        startMonitoring()
        observe()
        refresh()
    }

    func beginEditing(_ deviceID: String) {
        guard !isPaused, !isClosed, rows[deviceID]?.canWrite == true else { return }
        editing.insert(deviceID)
    }

    func setVolume(_ value: Float, for deviceID: String, isFinal: Bool = false) {
        guard !isPaused, !isClosed, let row = rows[deviceID], row.canWrite, let target = row.target else { return }
        guard AudioVolumeScalar.validScalar(value) else {
            rows[deviceID]?.issue = .invalidValue
            reportOperationFailure(.invalidValue)
            return
        }
        sequence &+= 1
        latestSequence[deviceID] = sequence
        if isFinal { editing.remove(deviceID) }
        rows[deviceID]?.draftValue = value
        // The previous operation remains unresolved until this request returns.
        // A queued preview alone cannot confirm that its failure is repaired.
        pending[deviceID]?.permit.cancel()
        permits[deviceID]?.cancel()
        let permit = AudioMutationPermit()
        pending[deviceID] = Request(target: target, value: value, sequence: sequence, isFinal: isFinal, permit: permit)
        // A superseded write may already be remote. Cancel its remaining
        // readback/unmute work, but keep tracking the actual task until return.
        if activeRequests.contains(deviceID), let writer = writers[deviceID] { tasks[writer]?.cancel() }
        startWriter(deviceID)
    }

    func endEditing(_ deviceID: String) {
        editing.remove(deviceID)
        if let value = rows[deviceID]?.draftValue { setVolume(value, for: deviceID, isFinal: true) }
    }

    func refresh() {
        guard !isPaused, !isClosed else { return }
        for binding in bindings {
            guard let target = binding.target, readers[binding.deviceID] == nil,
                  writers[binding.deviceID] == nil, !editing.contains(binding.deviceID) else { continue }
            let expectedSequence = latestSequence[binding.deviceID]
            rows[binding.deviceID]?.isReading = true
            let id = launch { [weak self, provider] in
                do {
                    let snapshot = try await provider.readVolume(for: target)
                    try Self.validate(snapshot, for: target)
                    guard let self, !Task.isCancelled, !self.isPaused, !self.isClosed,
                          self.rows[target.deviceID]?.target == target,
                          self.latestSequence[target.deviceID] == expectedSequence,
                          self.writers[target.deviceID] == nil,
                          snapshot.target == target else { return }
                    if let operationIssue = self.operationIssues[target.deviceID] {
                        self.operationIssues[target.deviceID] = Self.refreshedOperationIssue(snapshot, previous: operationIssue)
                    }
                    let refreshedIssue = self.operationIssues[target.deviceID] ??
                        Self.refreshedIssue(snapshot, previous: self.rows[target.deviceID]?.issue)
                    self.recordReadFailure(snapshot.capability.issue, for: target)
                    self.rows[target.deviceID]?.snapshot = snapshot
                    self.rows[target.deviceID]?.issue = refreshedIssue
                } catch {
                    guard let self, !Task.isCancelled, !self.isPaused, !self.isClosed,
                          self.rows[target.deviceID]?.target == target,
                          self.latestSequence[target.deviceID] == expectedSequence,
                          self.writers[target.deviceID] == nil else { return }
                    self.rows[target.deviceID]?.snapshot = nil
                    let issue = Self.issue(error)
                    self.recordReadFailure(issue, for: target)
                    self.rows[target.deviceID]?.issue = self.operationIssues[target.deviceID] ?? issue
                }
            } completion: { [weak self] taskID in
                guard let self, self.readers[target.deviceID] == taskID else { return }
                self.readers[target.deviceID] = nil
                self.rows[target.deviceID]?.isReading = false
                if Task.isCancelled { self.refresh() }
            }
            readers[binding.deviceID] = id
        }
    }

    /// Synchronous admission stop, required before selection/termination tasks
    /// are dispatched. Cancellation alone never declares a remote write absent.
    func pause() {
        guard !isClosed else { return }
        isPaused = true
        for request in pending.values { request.permit.cancel() }
        for permit in permits.values { permit.cancel() }
        pending.removeAll()
        editing.removeAll()
        monitor?.cancel()
        monitor = nil
        for task in tasks.values { task.cancel() }
        for id in rows.keys { rows[id]?.draftValue = nil }
    }

    func drain() async {
        // Tasks include work dispatched to the HAL actor but not yet registered
        // in its native gate, the setter, readback, and any unmute continuation.
        while !tasks.isEmpty {
            let batch = Array(tasks.values)
            for task in batch { await task.value }
        }
    }

    func resume() {
        guard !isClosed else { return }
        isPaused = false
        // Admission stays closed per row until a fresh read restores capability.
        for id in rows.keys {
            rows[id]?.snapshot = nil
            rows[id]?.draftValue = nil
        }
        startMonitoring()
        observe()
        refresh()
    }

    /// The owning hardware lifecycle closes its existing HAL gate first.
    /// This store does not own, replace, or reopen that gate.
    func shutdown() async {
        if !isClosed {
            pause()
            isClosed = true
            delivery?.close()
        }
        await drain()
        await provider.stopObservingVolume()
    }

    private func invalidate(_ deviceID: String) {
        pending[deviceID]?.permit.cancel()
        permits[deviceID]?.cancel()
        pending[deviceID] = nil
        editing.remove(deviceID)
        sequence &+= 1
        latestSequence[deviceID] = sequence
        if let writer = writers[deviceID] { tasks[writer]?.cancel() }
        if let reader = readers[deviceID] { tasks[reader]?.cancel() }
    }

    private func startWriter(_ deviceID: String) {
        guard writers[deviceID] == nil, pending[deviceID] != nil, !isPaused, !isClosed else { return }
        rows[deviceID]?.isWriting = true
        let id = launch { [weak self, provider, throttle] in
            guard let self else { return }
            do {
                if self.pending[deviceID]?.isFinal != true, let last = self.lastSubmission[deviceID] {
                    let remaining = throttle - last.duration(to: .now)
                    if remaining > .zero { try await Task.sleep(for: remaining) }
                }
                try Task.checkCancellation()
                guard !self.isPaused, !self.isClosed, let request = self.pending.removeValue(forKey: deviceID),
                      self.rows[deviceID]?.target == request.target else { return }
                self.permits[deviceID] = request.permit
                self.activeRequests.insert(deviceID)
                self.lastSubmission[deviceID] = .now
                let result: AudioVolumeWriteResult
                var isWritingToProvider = false
                do {
                    let resolved = try await self.resolveTarget(deviceID)
                    try Task.checkCancellation()
                    guard resolved == request.target, self.rows[deviceID]?.target == resolved,
                          self.latestSequence[deviceID] == request.sequence,
                          !self.isPaused, !self.isClosed else { throw AudioVolumeIssue.identityChanged }
                    isWritingToProvider = true
                    result = try await provider.setVolume(request.value, for: resolved, permit: request.permit)
                    try Self.validate(result.snapshot, for: resolved)
                }
                catch {
                    guard !Task.isCancelled, !self.isPaused, !self.isClosed,
                          self.rows[deviceID]?.target == request.target,
                          self.latestSequence[deviceID] == request.sequence else { return }
                    self.rows[deviceID]?.draftValue = nil
                    let issue = Self.issue(error, isWrite: isWritingToProvider)
                    self.operationIssues[deviceID] = issue
                    self.rows[deviceID]?.issue = issue
                    self.reportOperationFailure(issue)
                    // Read-only reconciliation of a failed write. Do not retry
                    // the setter or fabricate an unchanged remote state.
                    if let actual = try? await provider.readVolume(for: request.target),
                       (try? Self.validate(actual, for: request.target)) != nil,
                       !Task.isCancelled, self.rows[deviceID]?.target == request.target,
                       self.latestSequence[deviceID] == request.sequence, actual.target == request.target {
                        self.rows[deviceID]?.snapshot = actual
                    }
                    return
                }
                guard !Task.isCancelled, !self.isPaused, !self.isClosed,
                      self.rows[deviceID]?.target == request.target,
                      self.latestSequence[deviceID] == request.sequence,
                      result.snapshot.target == request.target else { return }
                self.rows[deviceID]?.snapshot = result.snapshot
                self.operationIssues[deviceID] = result.issue
                self.rows[deviceID]?.issue = result.issue ?? result.snapshot.capability.issue
                if let issue = result.issue { self.reportOperationFailure(issue) }
                if !self.editing.contains(deviceID) { self.rows[deviceID]?.draftValue = nil }
            } catch { /* Cancellation leaves the registered call tracked until it returns. */ }
        } completion: { [weak self] taskID in
            guard let self, self.writers[deviceID] == taskID else { return }
            self.writers[deviceID] = nil
            self.activeRequests.remove(deviceID)
            self.permits[deviceID] = nil
            self.rows[deviceID]?.isWriting = false
            self.startWriter(deviceID)
            if Task.isCancelled { self.refresh() }
        }
        writers[deviceID] = id
    }

    private func observe() {
        guard !isPaused, !isClosed else { return }
        if let observationID { tasks[observationID]?.cancel() }
        if delivery == nil { delivery = AudioChangeDelivery { [weak self] in self?.refresh() } }
        let targets = bindings.compactMap(\.target)
        guard let delivery else { return }
        observationID = launch { [weak self, provider] in
            do {
                try Task.checkCancellation()
                try await provider.observeVolumeChanges(targets: targets) { delivery.signal() }
                if !Task.isCancelled { self?.observationIssue = nil }
            } catch {
                if !Task.isCancelled { self?.observationIssue = .listenerUnavailable }
            }
        } completion: { [weak self] taskID in
            if self?.observationID == taskID { self?.observationID = nil }
        }
    }

    private func startMonitoring() {
        guard monitor == nil, !isPaused, !isClosed else { return }
        monitor = Task { [weak self, pollingInterval] in
            var nextObservationRetry = ContinuousClock.now.advanced(by: .seconds(30))
            while !Task.isCancelled {
                do { try await Task.sleep(for: pollingInterval) } catch { return }
                guard let self, !self.isPaused, !self.isClosed else { return }
                self.refresh()
                if self.observationIssue != nil, .now >= nextObservationRetry {
                    self.observe()
                    nextObservationRetry = .now.advanced(by: .seconds(30))
                }
            }
        }
    }

    private func launch(_ operation: @escaping @MainActor () async -> Void,
                        completion: @escaping @MainActor (UUID) -> Void = { _ in }) -> UUID {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await operation()
            completion(id)
            self?.tasks[id] = nil
        }
        return id
    }

    private static func issue(_ error: any Error, isWrite: Bool = false) -> AudioVolumeIssue {
        if let issue = error as? AudioVolumeIssue { return issue }
        let code = Int32(clamping: (error as NSError).code)
        return isWrite ? .writeFailed(code) : .readFailed(code)
    }

    private static func isFailure(_ issue: AudioVolumeIssue) -> Bool {
        switch issue {
        case .readFailed, .invalidReadback, .writeFailed, .unconfirmed, .mutedVolumeUnconfirmed,
             .unmutedVolumeUnconfirmed, .stillMuted, .muteUnknown, .invalidValue, .identityChanged:
            return true
        default: return false
        }
    }

    private func reportOperationFailure(_ issue: AudioVolumeIssue) {
        guard !isClosed, Self.isFailure(issue) else { return }
        failureEvent = PresentationFailure(message: issue.localizedDescription)
    }

    private func recordReadFailure(_ issue: AudioVolumeIssue?, for target: AudioVolumeTarget) {
        guard let issue, Self.isFailure(issue) else { readFailures[target] = nil; return }
        if readFailures[target] != issue { reportOperationFailure(issue) }
        readFailures[target] = issue
    }

    private static func validate(_ snapshot: AudioVolumeSnapshot, for target: AudioVolumeTarget) throws {
        guard snapshot.target == target else { throw AudioVolumeIssue.identityChanged }
        if let value = snapshot.value, !AudioVolumeScalar.validScalar(value) { throw AudioVolumeIssue.invalidReadback }
        if snapshot.capability.canWrite && snapshot.value == nil { throw AudioVolumeIssue.invalidReadback }
    }

    private static func refreshedOperationIssue(_ snapshot: AudioVolumeSnapshot, previous: AudioVolumeIssue) -> AudioVolumeIssue? {
        switch previous {
        case .mutedVolumeUnconfirmed, .unmutedVolumeUnconfirmed:
            if snapshot.mute.isAudiblyMuted { return .mutedVolumeUnconfirmed }
            return snapshot.mute == .unmuted ? .unmutedVolumeUnconfirmed : .unconfirmed
        case .stillMuted: return snapshot.mute.isAudiblyMuted ? previous : nil
        case .muteUnknown: return snapshot.mute == .unknown ? previous : nil
        default: return previous
        }
    }

    private static func refreshedIssue(_ snapshot: AudioVolumeSnapshot, previous: AudioVolumeIssue?) -> AudioVolumeIssue? {
        if let unavailable = snapshot.capability.issue { return unavailable }
        switch previous {
        case .writeFailed, .unconfirmed, .invalidValue, .identityChanged: return previous
        case .mutedVolumeUnconfirmed, .unmutedVolumeUnconfirmed:
            // A later refresh cannot confirm a request whose target is no
            // longer retained here. Keep the failure, but update mute wording.
            if snapshot.mute.isAudiblyMuted { return .mutedVolumeUnconfirmed }
            return snapshot.mute == .unmuted ? .unmutedVolumeUnconfirmed : .unconfirmed
        case .stillMuted: return snapshot.mute.isAudiblyMuted ? previous : nil
        case .muteUnknown: return snapshot.mute == .unknown ? previous : nil
        default: return nil
        }
    }
}
