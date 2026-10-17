import Foundation
import Observation

enum ShortcutSuspensionReason: Hashable { case switching, quitting, menu, modal, sleep }

enum ShortcutRegistrationState: Equatable {
    case registered, paused, failed(String)
}

struct ShortcutDeletionRequest: Identifiable, Equatable {
    let id: UUID
    let bindingID: UUID
    let revision: UUID
    let deviceName: String
}

@MainActor @Observable
final class ShortcutStore {
    private(set) var bindings: [ShortcutBinding] = []
    private(set) var registrationStates: [UUID: ShortcutRegistrationState] = [:]
    private(set) var editingMessage: String?
    private(set) var selectionFailure: String?
    private(set) var failureEvent: PresentationFailure?
    private enum MessageScope { case global, row(AudioTargetIdentity), success }
    private enum RowIssueKind: Equatable { case validation, operation }
    private struct RowIssue {
        let message: String
        let kind: RowIssueKind
        let draft: DeviceShortcut?
        let occupiedName: String?
    }
    private var messageScope = MessageScope.global
    private var rowIssues: [AudioTargetIdentity: RowIssue] = [:]
    private(set) var message: String? {
        get {
            switch storageOperation {
            case .loading: return String(localized: "shortcut.loading", defaultValue: "Loading shortcuts…")
            case .binding: return String(localized: "shortcut.saving", defaultValue: "Saving shortcuts…")
            case .idle, .names: return editingMessage ?? nameSaveFailure ?? selectionFailure
            }
        }
        set { editingMessage = newValue; messageScope = .global }
    }
    /// Row feedback and switch outcomes have their own presentation locations.
    /// Global configuration progress and recovery remain in the footer.
    var footerMessage: String? {
        switch storageOperation {
        case .loading: return String(localized: "shortcut.loading", defaultValue: "Loading shortcuts…")
        case .binding: return String(localized: "shortcut.saving", defaultValue: "Saving shortcuts…")
        case .idle, .names: break
        }
        if configuration == .failed { return editingMessage }
        if let nameSaveFailure { return nameSaveFailure }
        switch messageScope {
        case .success: return nil
        case .global: return editingMessage
        case let .row(target):
            // DeviceRowView renders a shortcut issue only when this exact
            // shortcut target is present. A backend display association or a
            // confirming placeholder alone does not display its explanation.
            let shownInMainList = devices.contains { $0.shortcutTarget == target }
            return shownInMainList ? nil : editingMessage
        }
    }
    private(set) var devices: [AudioDevice] = []
    private var discovery: AudioDiscoveryInventory = .unconfirmed

    private enum Lifecycle { case notStarted, running, closed }
    private enum Configuration { case unread, loaded, failed }
    private enum StorageOperation: Equatable {
        case idle, loading(UUID), binding(UUID), names(UUID)
        var id: UUID? {
            switch self {
            case .idle: nil
            case let .loading(id), let .binding(id), let .names(id): id
            }
        }
    }
    private struct Recording {
        let target: AudioTargetIdentity
        let deviceName: String
        let originalRevision: UUID?
    }
    private enum Editing {
        case idle, recording(Recording), deleting(ShortcutDeletionRequest), committing
    }
    private struct PendingSelection {
        let request: AudioSelectionRequest
        let bindingID: UUID
        let revision: UUID
    }
    private var lifecycle: Lifecycle = .notStarted
    private var configuration: Configuration = .unread
    private var storageOperation: StorageOperation = .idle
    private var editing: Editing = .idle
    private var suspensions: Set<ShortcutSuspensionReason> = []
    private var failedNameDocument: [ShortcutBinding]?
    private var nameSaveFailure: String?
    @ObservationIgnored private let preferences: any ShortcutPreferencesProviding
    @ObservationIgnored private let registrar: any GlobalShortcutRegistering
    @ObservationIgnored private let selectTarget: (AudioTargetIdentity, AudioSelectionRequest) -> Void
    @ObservationIgnored private let menuConflict: (DeviceShortcut) -> String?
    @ObservationIgnored private let initialBinding: @MainActor () async -> ShortcutBinding?
    @ObservationIgnored private var registrations: [UUID: GlobalShortcutRegistration] = [:]
    @ObservationIgnored private var pendingSelection: PendingSelection?
    @ObservationIgnored private var storageTask: Task<Void, Never>?

    init(selectTarget: @escaping @MainActor (AudioTargetIdentity, AudioSelectionRequest) -> Void,
         preferences: any ShortcutPreferencesProviding = ShortcutPreferences(),
         registrar: any GlobalShortcutRegistering = GlobalShortcutService(),
         menuConflict: @escaping @MainActor (DeviceShortcut) -> String? = { _ in nil },
         initialBinding: @escaping @MainActor () async -> ShortcutBinding? = { nil }) {
        self.selectTarget = selectTarget
        self.preferences = preferences
        self.registrar = registrar
        self.menuConflict = menuConflict
        self.initialBinding = initialBinding
    }

    var isRecording: Bool {
        if case .recording = editing { return true }
        return false
    }

    var canEdit: Bool {
        guard lifecycle == .running, configuration == .loaded,
              storageOperation == .idle, suspensions.isEmpty else { return false }
        switch editing { case .idle, .recording: return true; case .deleting, .committing: return false }
    }

    var recoveryTitle: String? {
        guard lifecycle == .running else { return nil }
        if configuration == .failed { return String(localized: "shortcut.reload", defaultValue: "Reload") }
        if registrationStates.values.contains(where: { if case .failed = $0 { true } else { false } }) {
            return String(localized: "shortcut.retry_registration", defaultValue: "Retry Registration")
        }
        if failedNameDocument != nil { return String(localized: "shortcut.retry_save", defaultValue: "Retry Save") }
        return nil
    }

    var canRecover: Bool {
        guard lifecycle == .running, storageOperation == .idle, suspensions.isEmpty,
              case .idle = editing else { return false }
        return recoveryTitle != nil
    }

    func retryRecovery() {
        guard canRecover else { return }
        if configuration == .failed { loadPreferences(); return }
        if registrationStates.values.contains(where: { if case .failed = $0 { true } else { false } }) {
            message = nil
            restoreRegistrations()
            updateDelivery()
        } else {
            failedNameDocument = nil
            nameSaveFailure = nil
            saveRenamedDevicesIfNeeded()
        }
    }

    var offlineBindings: [ShortcutBinding] {
        bindings.filter { discovery.presence(of: $0.target) == .missing }
    }

    /// Saved targets with incomplete evidence remain in the discovered section.
    /// A display association prevents duplicate rows but grants no capability.
    var confirmingBindings: [ShortcutBinding] {
        bindings.filter { binding in
            discovery.presence(of: binding.target) != .missing &&
                !devices.contains { $0.represents(binding.target) }
        }
    }

    func canRecord(target: AudioTargetIdentity) -> Bool {
        canEdit && devices.filter { $0.shortcutTarget == target }.count == 1
    }

    func binding(for target: AudioTargetIdentity) -> ShortcutBinding? {
        bindings.first { $0.target == target }
    }

    func isRecording(target: AudioTargetIdentity) -> Bool {
        if case let .recording(recording) = editing { return recording.target == target }
        return false
    }

    func rowIssue(for target: AudioTargetIdentity) -> String? {
        if let issue = rowIssues[target] {
            if let name = issue.occupiedName, let draft = issue.draft {
                return String(localized: "shortcut.occupied_by", defaultValue: "\(ShortcutKeyDisplay.label(draft)) is assigned to \(name)")
            }
            return issue.message
        }
        if let binding = binding(for: target), case let .failed(reason) = registrationStates[binding.id] {
            return reason
        }
        return nil
    }

    func rowDraftLabel(for target: AudioTargetIdentity) -> String? {
        guard isRecording(target: target), let draft = rowIssues[target]?.draft else { return nil }
        return ShortcutKeyDisplay.label(draft)
    }

    private func setRowIssue(_ text: String, for target: AudioTargetIdentity,
                             kind: RowIssueKind = .operation, draft: DeviceShortcut? = nil,
                             occupiedName: String? = nil) {
        rowIssues[target] = RowIssue(message: text, kind: kind, draft: draft, occupiedName: occupiedName)
        editingMessage = text
        messageScope = .row(target)
        if lifecycle == .running {
            let eventMessage = occupiedName.flatMap { name in draft.map { String(localized: "shortcut.occupied_by", defaultValue: "\(ShortcutKeyDisplay.label($0)) is assigned to \(name)") } } ?? text
            failureEvent = PresentationFailure(message: eventMessage)
        }
    }

    private func setSuccess(_ text: String, for target: AudioTargetIdentity) {
        rowIssues[target] = nil
        editingMessage = text
        messageScope = .success
    }

    func start() {
        guard lifecycle == .notStarted else { return }
        lifecycle = .running
        registrar.setDeliveryEnabled(false)
        registrar.onPress = { [weak self] in self?.pressed($0) }
        loadPreferences()
    }

    private func loadPreferences() {
        guard lifecycle == .running, storageOperation == .idle else { return }
        let id = UUID()
        storageOperation = .loading(id)
        updateDelivery()
        storageTask = Task { [self] in
            defer { finishStorageOperation(id) }
            do {
                let existing = try await preferences.load()
                guard lifecycle == .running, storageOperation.id == id else { return }
                let loaded: [ShortcutBinding]
                if let existing {
                    loaded = existing
                } else {
                    let initial = await initialBinding()
                    guard lifecycle == .running, storageOperation.id == id else { return }
                    loaded = initial.map { [$0] } ?? []
                    try ShortcutPreferences.validate(loaded)
                    // Save even an empty result to mark first-launch setup as
                    // handled. Registration starts only after the real write.
                    try await preferences.save(loaded)
                    guard lifecycle == .running, storageOperation.id == id else { return }
                }
                try ShortcutPreferences.validate(loaded)
                bindings = loaded
                configuration = .loaded
                message = nil
                restoreRegistrations()
            } catch {
                guard lifecycle == .running, storageOperation.id == id else { return }
                configuration = .failed
                // Existing unreadable/newer files are never reset. A missing
                // file may retry its failed first-launch initialization.
                message = error.localizedDescription
                failureEvent = PresentationFailure(message: error.localizedDescription)
            }
        }
    }

    func updateDevices(_ devices: [AudioDevice], discovery: AudioDiscoveryInventory = .unconfirmed) {
        guard lifecycle != .closed else { return }
        self.devices = devices
        self.discovery = discovery
        // Discovery changes neither registration ownership nor audio output.
        saveRenamedDevicesIfNeeded()
        if case let .recording(recording) = editing,
           devices.filter({ $0.shortcutTarget == recording.target }).count != 1 {
            cancelRecording()
        }
    }

    func setSuspended(_ reason: ShortcutSuspensionReason, _ suspended: Bool) {
        guard lifecycle != .closed else { return }
        if suspended {
            suspensions.insert(reason)
            updateDelivery() // Synchronous gate precedes any restoration work.
            if reason == .quitting {
                pendingSelection = nil
                if case .deleting = editing { editing = .idle }
            }
            cancelRecording()
        } else {
            suspensions.remove(reason)
            if reason == .quitting, case .idle = editing { restoreRegistrations() }
            saveRenamedDevicesIfNeeded()
        }
        updateDelivery()
    }

    @discardableResult
    func beginRecording(target: AudioTargetIdentity, deviceName: String) -> Bool {
        guard canEdit else { return false }
        if isRecording(target: target) { return true }
        guard case .idle = editing else { return false }
        let original = binding(for: target)
        guard canRecord(target: target) else {
            setRowIssue(String(localized: "shortcut.identity_unconfirmed", defaultValue: "A shortcut cannot be set until this device is uniquely identified."), for: target)
            return false
        }
        editing = .recording(Recording(target: target, deviceName: deviceName,
                                       originalRevision: original?.revision))
        // Explicitly editing this target handles its prior operation feedback.
        rowIssues[target] = nil
        message = nil
        updateDelivery()
        var failures: [String] = []
        do { try registrar.retryFailedCleanup(for: nil) }
        catch { failures.append(error.localizedDescription) }
        for binding in bindings {
            if let registration = registrations.removeValue(forKey: binding.id) {
                do { try registrar.unregister(registration) }
                catch { failures.append(error.localizedDescription) }
            }
            registrationStates[binding.id] = .paused
        }
        guard failures.isEmpty else {
            editing = .idle
            restoreRegistrations()
            setRowIssue(String(localized: "shortcut.pause_failed", defaultValue: "Could not pause all shortcuts. Recording was cancelled. \(failures.joined(separator: " "))"), for: target)
            updateDelivery()
            return false
        }
        return true
    }

    func cancelRecording() {
        guard case let .recording(recording) = editing else { return }
        if rowIssues[recording.target]?.kind == .validation {
            rowIssues[recording.target] = nil
            if case let .row(target) = messageScope, target == recording.target { message = nil }
        }
        editing = .idle
        if lifecycle == .running { restoreRegistrations() }
        updateDelivery()
    }

    /// Validation errors keep the recording active, allowing a replacement key.
    func recordingRejected(_ error: any Error) {
        guard case let .recording(recording) = editing else { return }
        setRowIssue(error.localizedDescription, for: recording.target, kind: .validation)
    }

    /// True means the gesture was accepted. File completion, registration
    /// compensation and success feedback happen asynchronously; drain observes
    /// their actual completion, including during final shutdown.
    @discardableResult
    func commitRecording(_ shortcut: DeviceShortcut) -> Bool {
        guard lifecycle == .running, configuration == .loaded, storageOperation == .idle, suspensions.isEmpty,
              case let .recording(recording) = editing else { return false }
        let original = binding(for: recording.target)
        guard original?.revision == recording.originalRevision else {
            setRowIssue(String(localized: "shortcut.binding_changed", defaultValue: "The shortcut changed. Record it again."), for: recording.target)
            cancelRecording()
            return false
        }
        if original?.shortcut == shortcut {
            cancelRecording()
            return true
        }
        do { try validateCandidate(shortcut, excluding: original?.id) }
        catch {
            let occupiedName: String?
            if let shortcutError = error as? ShortcutError, case let .duplicateBinding(name) = shortcutError {
                occupiedName = name
            }
            else { occupiedName = nil }
            setRowIssue(error.localizedDescription, for: recording.target, kind: .validation,
                        draft: shortcut, occupiedName: occupiedName)
            return false
        }

        rowIssues[recording.target] = nil
        editing = .committing
        // Restore old keys before changing them. A failed restoration remains
        // explicit; a different working candidate can still replace it.
        restoreRegistrations()
        let candidate = ShortcutBinding(id: original?.id ?? UUID(), target: recording.target,
                                        shortcut: shortcut, lastKnownName: recording.deviceName)
        let oldRegistration = original.flatMap { registrations[$0.id] }
        var candidateRegistration: GlobalShortcutRegistration?
        do {
            candidateRegistration = try registrar.register(shortcut)
            if let oldRegistration {
                registrations[candidate.id] = nil
                registrationStates[candidate.id] = .paused
                try registrar.unregister(oldRegistration)
            }
        } catch {
            failRecordingSave(error, target: recording.target, candidateRegistration: candidateRegistration)
            return false
        }
        let next = renamedBindings(bindings.filter { $0.id != candidate.id } + [candidate])
        let id = UUID()
        pendingSelection = nil
        storageOperation = .binding(id)
        storageTask = Task { [self, candidateRegistration] in
            defer { finishStorageOperation(id) }
            do {
                try await preferences.save(next)
                guard lifecycle == .running, storageOperation.id == id else { return }
                bindings = next
                failedNameDocument = nil
                nameSaveFailure = nil
                registrations[candidate.id] = candidateRegistration
                registrationStates[candidate.id] = .registered
                setSuccess(String(localized: "shortcut.binding_saved", defaultValue: "Shortcut set for \(recording.deviceName)."), for: recording.target)
                editing = .idle
            } catch {
                guard lifecycle == .running, storageOperation.id == id else { return }
                failRecordingSave(error, target: recording.target, candidateRegistration: candidateRegistration)
            }
        }
        return true
    }

    private func failRecordingSave(_ error: any Error, target: AudioTargetIdentity,
                                   candidateRegistration: GlobalShortcutRegistration?) {
        var cleanupError: String?
        if let candidateRegistration {
            do { try registrar.unregister(candidateRegistration) }
            catch { cleanupError = error.localizedDescription }
        }
        editing = .idle
        restoreRegistrations()
        var failure = String(localized: "shortcut.save_failed", defaultValue: "The new shortcut was not saved: \(error.localizedDescription)")
        if let cleanupError { failure += String(localized: "shortcut.temporary_release_failed", defaultValue: " Could not release the temporary shortcut registration: \(cleanupError)") }
        setRowIssue(failure, for: target)
        updateDelivery()
    }

    /// Backspace clears only the active recorder. A new empty recorder ends
    /// without rewriting preferences or manufacturing a saved device record.
    @discardableResult
    func clearRecording() -> Bool {
        guard lifecycle == .running, configuration == .loaded, storageOperation == .idle,
              suspensions.isEmpty, case let .recording(recording) = editing else { return false }
        let original = binding(for: recording.target)
        guard original?.revision == recording.originalRevision else {
            setRowIssue(String(localized: "shortcut.binding_changed", defaultValue: "The shortcut changed. Record it again."), for: recording.target)
            cancelRecording()
            return false
        }
        guard let original else {
            cancelRecording()
            return true
        }
        return removeBinding(original, deviceName: recording.deviceName, action: .clearShortcut)
    }

    func requestRecordRemoval(bindingID: UUID) -> ShortcutDeletionRequest? {
        guard canEdit, let binding = bindings.first(where: { $0.id == bindingID }),
              discovery.presence(of: binding.target) == .missing else { return nil }
        if isRecording { cancelRecording() }
        guard case .idle = editing else { return nil }
        let request = ShortcutDeletionRequest(id: UUID(), bindingID: binding.id,
                                               revision: binding.revision, deviceName: displayName(for: binding))
        editing = .deleting(request)
        updateDelivery()
        return request
    }

    func cancelDeletion(_ request: ShortcutDeletionRequest) {
        guard case let .deleting(current) = editing, current == request else { return }
        editing = .idle
        updateDelivery()
        saveRenamedDevicesIfNeeded()
    }

    /// True means the confirmed deletion was admitted, not that disk has saved.
    @discardableResult
    func confirmDeletion(_ request: ShortcutDeletionRequest) -> Bool {
        guard lifecycle == .running, configuration == .loaded, storageOperation == .idle,
              !suspensions.contains(.quitting),
              case let .deleting(current) = editing, current == request,
              let binding = bindings.first(where: { $0.id == request.bindingID }),
              binding.revision == request.revision else { return false }
        guard discovery.presence(of: binding.target) == .missing else {
            cancelDeletion(request)
            message = String(localized: "shortcut.discovery_changed", defaultValue: "The device discovery state changed. The record was not removed.")
            failureEvent = PresentationFailure(message: String(localized: "shortcut.discovery_changed", defaultValue: "The device discovery state changed. The record was not removed."))
            return false
        }
        return removeBinding(binding, deviceName: request.deviceName, action: .removeRecord)
    }

    private enum RemovalAction {
        case clearShortcut, removeRecord
        var failure: String { self == .clearShortcut ? String(localized: "shortcut.clear_failed", defaultValue: "The shortcut was not cleared") : String(localized: "shortcut.record_removal_failed", defaultValue: "The device record was not removed") }
        func success(deviceName: String) -> String {
            self == .clearShortcut ? String(localized: "shortcut.cleared", defaultValue: "Shortcut cleared for \(deviceName).") : String(localized: "shortcut.record_removed", defaultValue: "Local record removed for \(deviceName).")
        }
    }

    /// Both gestures share one unregister/save/compensation transaction. The
    /// caller has already checked its distinct recording or absence evidence.
    private func removeBinding(_ binding: ShortcutBinding, deviceName: String, action: RemovalAction) -> Bool {
        rowIssues[binding.target] = nil
        editing = .committing
        let next = renamedBindings(bindings.filter { $0.id != binding.id })
        do {
            // A prior failed unregister may have invalidated its delivery token
            // while leaving the native combination occupied. Deleting a retry
            // cannot discard the last management record until it is released.
            try registrar.retryFailedCleanup(for: binding.shortcut)
            if let registration = registrations.removeValue(forKey: binding.id) {
                registrationStates[binding.id] = .paused
                try registrar.unregister(registration)
            }
        }
        catch {
            editing = .idle
            restoreRegistrations()
            setRowIssue(String(localized: "shortcut.removal_error_detail", defaultValue: "\(action.failure): \(error.localizedDescription)"), for: binding.target)
            updateDelivery()
            return false
        }
        if pendingSelection?.bindingID == binding.id { pendingSelection = nil }
        let id = UUID()
        storageOperation = .binding(id)
        storageTask = Task { [self] in
            defer { finishStorageOperation(id) }
            do {
                try await preferences.save(next)
                guard lifecycle == .running, storageOperation.id == id else { return }
                bindings = next
                failedNameDocument = nil
                nameSaveFailure = nil
                registrationStates[binding.id] = nil
                editing = .idle
                restoreRegistrations()
                setSuccess(action.success(deviceName: deviceName), for: binding.target)
            } catch {
                guard lifecycle == .running, storageOperation.id == id else { return }
                editing = .idle
                restoreRegistrations()
                setRowIssue(String(localized: "shortcut.removal_error_detail", defaultValue: "\(action.failure): \(error.localizedDescription)"), for: binding.target)
            }
        }
        return true
    }

    @discardableResult
    func handleSelectionResult(_ result: AudioSelectionResult) -> Bool {
        guard lifecycle == .running, !suspensions.contains(.quitting),
              let pending = pendingSelection, pending.request == result.request,
              bindings.contains(where: { $0.id == pending.bindingID && $0.revision == pending.revision }) else { return false }
        pendingSelection = nil
        if case let .failed(reason) = result.outcome {
            selectionFailure = reason
            return true
        }
        if result.outcome == .selected || result.outcome == .alreadySelected { selectionFailure = nil }
        return false
    }

    func displayName(for binding: ShortcutBinding) -> String {
        let matches = devices.filter { $0.shortcutTarget == binding.target }
        return matches.count == 1 ? matches[0].name : binding.lastKnownName
    }

    func stop() {
        guard lifecycle != .closed else { return }
        lifecycle = .closed
        editing = .idle
        pendingSelection = nil
        registrar.setDeliveryEnabled(false)
        registrar.onPress = nil
        registrations.removeAll()
        do { try registrar.close() }
        catch { message = error.localizedDescription }
    }

    /// Waits for accepted file work, rather than treating Task cancellation as
    /// proof that the file was not replaced. Final shutdown closes admission
    /// before awaiting this method, so no follow-up writes are started.
    func drain() async {
        while let task = storageTask { await task.value }
    }

    private func finishStorageOperation(_ id: UUID) {
        guard storageOperation.id == id else { return }
        storageOperation = .idle
        storageTask = nil
        guard lifecycle == .running else { return }
        updateDelivery()
        saveRenamedDevicesIfNeeded()
    }

    private func renamedBindings(_ values: [ShortcutBinding]) -> [ShortcutBinding] {
        values.map { binding in
            let matches = devices.filter { $0.shortcutTarget == binding.target }
            guard matches.count == 1, matches[0].name != binding.lastKnownName else { return binding }
            return ShortcutBinding(id: binding.id, target: binding.target, shortcut: binding.shortcut,
                                   lastKnownName: matches[0].name, revision: binding.revision)
        }
    }

    private func saveRenamedDevicesIfNeeded() {
        guard lifecycle == .running, configuration == .loaded, storageOperation == .idle,
              suspensions.isEmpty, case .idle = editing else { return }
        let next = renamedBindings(bindings)
        guard next != bindings else {
            failedNameDocument = nil
            nameSaveFailure = nil
            return
        }
        // A repeated directory notification is not a request to retry failed
        // storage. Only a changed document or the recovery button tries again.
        guard next != failedNameDocument else { return }
        let id = UUID()
        storageOperation = .names(id)
        storageTask = Task { [self] in
            defer { finishStorageOperation(id) }
            do {
                try await preferences.save(next)
                guard lifecycle == .running, storageOperation.id == id else { return }
                bindings = next
                failedNameDocument = nil
                nameSaveFailure = nil
            } catch {
                guard lifecycle == .running, storageOperation.id == id else { return }
                failedNameDocument = next
                let failure = String(localized: "shortcut.name_cache_failed", defaultValue: "The device name cache was not saved: \(error.localizedDescription)")
                nameSaveFailure = failure
                failureEvent = PresentationFailure(message: failure)
            }
        }
    }

    private func validateCandidate(_ shortcut: DeviceShortcut, excluding id: UUID?) throws {
        if let duplicate = bindings.first(where: { $0.id != id && $0.shortcut == shortcut }) {
            throw ShortcutError.duplicateBinding(displayName(for: duplicate))
        }
        if let name = menuConflict(shortcut) { throw ShortcutError.menuConflict(name) }
        if try registrar.systemShortcuts().contains(shortcut) { throw ShortcutError.systemConflict }
    }

    private func restoreRegistrations() {
        guard lifecycle == .running, configuration == .loaded, !suspensions.contains(.quitting) else { return }
        let missing = bindings.filter { registrations[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let system: Set<DeviceShortcut>
        do { system = try registrar.systemShortcuts() }
        catch {
            for binding in missing { registrationStates[binding.id] = .failed(error.localizedDescription) }
            message = error.localizedDescription
            failureEvent = PresentationFailure(message: error.localizedDescription)
            return
        }
        for binding in missing {
            do {
                if let name = menuConflict(binding.shortcut) { throw ShortcutError.menuConflict(name) }
                if system.contains(binding.shortcut) { throw ShortcutError.systemConflict }
                registrations[binding.id] = try registrar.register(binding.shortcut)
                registrationStates[binding.id] = .registered
            } catch {
                registrationStates[binding.id] = .failed(error.localizedDescription)
                let failure = String(localized: "shortcut.device_error_detail", defaultValue: "\(displayName(for: binding)): \(error.localizedDescription)")
                editingMessage = failure
                messageScope = .row(binding.target)
                failureEvent = PresentationFailure(message: failure)
            }
        }
    }

    private func updateDelivery() {
        let idle: Bool
        if case .idle = editing { idle = true } else { idle = false }
        registrar.setDeliveryEnabled(lifecycle == .running && configuration == .loaded && idle && suspensions.isEmpty)
    }

    private func pressed(_ registration: GlobalShortcutRegistration) {
        guard lifecycle == .running, configuration == .loaded, suspensions.isEmpty, case .idle = editing,
              let id = registrations.first(where: { $0.value == registration })?.key,
              let binding = bindings.first(where: { $0.id == id }) else { return }
        let request = AudioSelectionRequest(id: UUID(), origin: .shortcut(bindingID: binding.id))
        editingMessage = nil
        pendingSelection = PendingSelection(request: request, bindingID: binding.id, revision: binding.revision)
        // The shared selection entry re-resolves current identity/capability and
        // emits a typed synchronous rejection for offline/ambiguous targets.
        selectTarget(binding.target, request)
    }
}
