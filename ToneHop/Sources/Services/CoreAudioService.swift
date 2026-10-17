import CoreAudio
import Foundation
import IOKit.audio

protocol AudioHardwareProviding: Sendable {
    var serviceEpoch: AudioServiceEpoch? { get }
    func beginShutdown()
    func snapshot() async throws -> CoreAudioSnapshot
    func builtInSpeaker() async throws -> AudioDevice
    func select(uid: String) async throws
    func observeChanges(_ changed: @escaping @Sendable () -> Void) async throws
    func observeEvents(_ changed: @escaping @Sendable (AudioHardwareEvent) -> Void) async throws
    func stopObserving() async
}

extension AudioHardwareProviding {
    var serviceEpoch: AudioServiceEpoch? { nil }
    func observeEvents(_ changed: @escaping @Sendable (AudioHardwareEvent) -> Void) async throws {
        try await observeChanges { changed(.changed) }
    }
    func builtInSpeaker() async throws -> AudioDevice {
        throw AudioServiceError.unavailable(String(localized: "audio.speaker_verification_unsupported", defaultValue: "The current audio service cannot verify the built-in Mac speakers."))
    }
}

enum AudioHardwareReadFailure: LocalizedError {
    case unstableInventory

    var errorDescription: String? {
        String(localized: "audio.speaker_inventory_unstable", defaultValue: "Audio devices are still changing. The built-in Mac speakers cannot be reliably confirmed yet.")
    }

    static func isTransient(_ error: any Error) -> Bool {
        if error is AudioHardwareReadFailure { return true }
        guard case let AudioServiceError.system(_, status) = error else { return false }
        return status == kAudioHardwareBadObjectError || status == kAudioHardwareBadDeviceError
    }
}

/// HAL transport describes the connection, not the acoustic terminal. In
/// particular, a built-in headphone jack must never satisfy a speaker request.
enum BuiltInSpeakerSelection {
    struct DeviceIdentity: Equatable, Sendable {
        let objectID: AudioObjectID
        let uid: String
        let transportType: UInt32
    }

    struct Inventory: Equatable, Sendable {
        let identities: [DeviceIdentity]
        let candidates: [Candidate]
    }

    struct Stream: Equatable, Sendable {
        let objectID: AudioObjectID
        let direction: UInt32
        let terminalType: UInt32
    }

    struct Candidate: Equatable, Sendable {
        let objectID: AudioObjectID
        let device: AudioDevice
        let transportType: UInt32
        let alive: Bool
        let canBeDefaultOutput: Bool
        let hidden: Bool
        let outputChannelCount: UInt32
        let streams: [Stream]
    }

    /// A disappearing AirPlay object can invalidate an unrelated directory read.
    /// Restart the complete pair so partial identity evidence is never reused.
    /// The caller's isolation keeps HAL reads on CoreAudioService's actor.
    static func readStableInventory(
        isolation: isolated (any Actor)? = #isolation,
        read: () throws -> Inventory,
        checkRunning: () throws -> Void = {},
        wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async throws -> Inventory {
        func checkActive() throws {
            try Task.checkCancellation()
            try checkRunning()
        }
        for attempt in 0..<4 {
            try checkActive()
            do {
                let first = try read()
                try checkActive()
                let second = try read()
                try checkActive()
                if first == second { return second }
            } catch {
                guard AudioHardwareReadFailure.isTransient(error) else { throw error }
            }
            guard attempt < 3 else { break }
            try await wait()
        }
        try checkActive()
        throw AudioHardwareReadFailure.unstableInventory
    }

    static func resolve(_ candidates: [Candidate], deviceUIDs: [String]) throws -> AudioDevice {
        var speakers: [AudioDevice] = []
        // HAL drivers can return either Core Audio's four-character terminal
        // constants or the public IOAudioTypes terminal values. Both describe
        // the acoustic endpoint; neither is a device UID or display-name rule.
        let speakerTerminals: Set<UInt32> = [kAudioStreamTerminalTypeSpeaker, UInt32(OUTPUT_SPEAKER)]
        let lfeTerminals: Set<UInt32> = [kAudioStreamTerminalTypeLFESpeaker, UInt32(OUTPUT_LOW_FREQUENCY_EFFECTS_SPEAKER)]
        let knownTerminals: Set<UInt32> = [
            kAudioStreamTerminalTypeLine, kAudioStreamTerminalTypeDigitalAudioInterface,
            kAudioStreamTerminalTypeSpeaker, kAudioStreamTerminalTypeHeadphones,
            kAudioStreamTerminalTypeLFESpeaker, kAudioStreamTerminalTypeReceiverSpeaker,
            kAudioStreamTerminalTypeMicrophone, kAudioStreamTerminalTypeHeadsetMicrophone,
            kAudioStreamTerminalTypeReceiverMicrophone, kAudioStreamTerminalTypeTTY,
            kAudioStreamTerminalTypeHDMI, kAudioStreamTerminalTypeDisplayPort,
            UInt32(OUTPUT_SPEAKER), UInt32(OUTPUT_HEADPHONES), UInt32(OUTPUT_HEAD_MOUNTED_DISPLAY_AUDIO),
            UInt32(OUTPUT_DESKTOP_SPEAKER), UInt32(OUTPUT_ROOM_SPEAKER), UInt32(OUTPUT_COMMUNICATION_SPEAKER),
            UInt32(OUTPUT_LOW_FREQUENCY_EFFECTS_SPEAKER),
            UInt32(EXTERNAL_ANALOG_CONNECTOR), UInt32(EXTERNAL_DIGITAL_AUDIO_INTERFACE),
            UInt32(EXTERNAL_LINE_CONNECTOR), UInt32(EXTERNAL_LEGACY_AUDIO_CONNECTOR), UInt32(EXTERNAL_SPDIF_INTERFACE),
        ]
        for candidate in candidates {
            guard candidate.transportType == kAudioDeviceTransportTypeBuiltIn,
                  candidate.alive, candidate.canBeDefaultOutput, !candidate.hidden,
                  candidate.outputChannelCount > 0 else { continue }
            guard !candidate.streams.isEmpty,
                  Set(candidate.streams.map(\.objectID)).count == candidate.streams.count,
                  candidate.streams.allSatisfy({ $0.direction == 0 && knownTerminals.contains($0.terminalType) }) else {
                throw AudioServiceError.unavailable(String(localized: "audio.speaker_terminal_unconfirmed", defaultValue: "The built-in audio output terminal is not yet identified. No output was selected for quitting."))
            }
            guard candidate.streams.contains(where: { speakerTerminals.contains($0.terminalType) }) else { continue }
            guard candidate.streams.allSatisfy({
                speakerTerminals.contains($0.terminalType) || lfeTerminals.contains($0.terminalType)
            }) else {
                throw AudioServiceError.unavailable(String(localized: "audio.speaker_terminal_ambiguous", defaultValue: "The built-in device also exposes other outputs. The built-in Mac speakers cannot be identified separately."))
            }
            guard candidate.device.isAvailable, case let .coreAudio(uid) = candidate.device.backend,
                  !uid.isEmpty, candidate.device.id == "hal:\(uid)",
                  deviceUIDs.filter({ $0 == uid }).count == 1 else {
                throw AudioServiceError.ambiguousIdentity
            }
            speakers.append(candidate.device)
        }
        guard speakers.count == 1, let speaker = speakers.first else {
            if speakers.count > 1 { throw AudioServiceError.ambiguousIdentity }
            throw AudioServiceError.unavailable(String(localized: "audio.speakers_missing", defaultValue: "No uniquely identified built-in Mac speakers were found. No other audio device was selected."))
        }
        return speaker
    }
}

/// All HAL calls run on this actor, away from UI rendering. A write is only a request;
/// AudioStore confirms it by reading the live default output again.
actor CoreAudioService: AudioHardwareProviding {
    typealias DirectoryListenerFactory = @Sendable (
        AudioObjectID, AudioObjectPropertyAddress, DispatchQueue,
        @escaping AudioObjectPropertyListenerBlock
    ) -> THVolumeListenerToken

    private struct DirectoryObserver {
        let token: THVolumeListenerToken
        let delivery: AudioVolumeListenerDelivery
    }
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private nonisolated let shutdownSignal = AudioShutdownSignal()
    nonisolated let serviceEpoch: AudioServiceEpoch? = AudioServiceEpoch()
    private var observerGeneration: UUID?
    private var observers: [DirectoryObserver] = []
    private let makeDirectoryListener: DirectoryListenerFactory
    // Independent collection: directory listener retries never remove volume listeners.
    var volumeObservationState = CoreAudioVolumeObservationState()
    let volumeIO: any CoreAudioVolumeIO

    init(volumeIO: any CoreAudioVolumeIO = SystemCoreAudioVolumeIO(),
         makeDirectoryListener: @escaping DirectoryListenerFactory = {
             THVolumeListenerToken(object: $0, address: $1, queue: $2, callback: $3)
         }) {
        self.volumeIO = volumeIO
        self.makeDirectoryListener = makeDirectoryListener
    }

    func snapshot() throws -> CoreAudioSnapshot {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        let lease = try AudioServiceOperation.capture(from: serviceEpoch)
        let objects = try deviceIDs()
        let current: UInt32 = try scalar(system, kAudioHardwarePropertyDefaultOutputDevice)
        let sound: UInt32 = try scalar(system, kAudioHardwarePropertyDefaultSystemOutputDevice)
        var devices: [AudioDevice] = []
        var warnings: [String] = []
        var identities: [AudioObjectID: String] = [:]
        var rawIdentities: [CoreAudioObjectIdentity] = []
        var completeIdentityRead = true
        for object in objects {
            do {
                let uid = try string(object, kAudioDevicePropertyDeviceUID)
                guard !uid.isEmpty else { completeIdentityRead = false; continue }
                rawIdentities.append(CoreAudioObjectIdentity(objectID: object, uid: uid))
            } catch { completeIdentityRead = false }
        }
        let uniqueObjects = CoreAudioIdentityInventory.confirmedObjects(rawIdentities, complete: completeIdentityRead)

        var completeOutputRead = true
        for object in objects {
            do {
                guard try outputChannelCount(object) > 0 else { continue }
                let alive: UInt32 = try scalar(object, kAudioDevicePropertyDeviceIsAlive)
                let eligible: UInt32 = try scalar(object, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput)
                let hidden: UInt32
                do { hidden = try scalar(object, kAudioDevicePropertyIsHidden) }
                catch {
                    // Preserve the existing display fallback, but an unknown
                    // exclusion property cannot establish complete absence.
                    hidden = 0
                    completeOutputRead = false
                }
                guard hidden == 0, eligible != 0, alive != 0 else { continue }
                let uid = try string(object, kAudioDevicePropertyDeviceUID)
                guard !uid.isEmpty else { completeOutputRead = false; continue }
                let name = try string(object, kAudioObjectPropertyName)
                let type: UInt32 = try scalar(object, kAudioDevicePropertyTransportType)
                let id = "hal:\(uid)"
                identities[object] = id
                let kind = transport(type)
                let target: AudioTargetIdentity? = uniqueObjects[uid] == object && kind != .airplay
                    ? .hal(uid: uid) : nil
                devices.append(AudioDevice(id: id, name: name, transport: kind, backend: .coreAudio(uid: uid),
                                           shortcutTarget: target,
                                           icon: deviceIcon(object, uid: uid, name: name, transportType: type,
                                                uniqueObject: uniqueObjects[uid] == object,
                                                rawUIDs: rawIdentities.map(\.uid))))
            } catch {
                // Devices can disappear during enumeration. Keep valid rows, report incompleteness.
                completeOutputRead = false
                warnings.append(String(localized: "audio.device_read_failed", defaultValue: "Reading device \(Int(object)): \(error.localizedDescription)"))
            }
        }

        let duplicateIDs = Set(Dictionary(grouping: devices, by: \.id).filter { $0.value.count > 1 }.keys)
        if !duplicateIDs.isEmpty {
            warnings.append(String(localized: "audio.duplicate_identifiers", defaultValue: "Duplicate device identifiers were found. The affected devices cannot be selected right now."))
            var seen = Set<String>()
            devices = devices.compactMap { device in
                guard seen.insert(device.id).inserted else { return nil }
                var result = device
                if duplicateIDs.contains(device.id) {
                    result.isAvailable = false
                    result.unavailableReason = AudioServiceError.ambiguousIdentity.localizedDescription
                    result.shortcutTarget = nil
                }
                return result
            }
        }
        // Absence requires a complete, stable raw identity inventory, including
        // entries omitted from presentation. A failed or changing second read
        // only withholds absence evidence; it does not erase healthy rows.
        let stableIdentityRead: Bool
        do {
            let finalObjects = try deviceIDs()
            let finalIdentities = try finalObjects.map {
                CoreAudioObjectIdentity(objectID: $0, uid: try string($0, kAudioDevicePropertyDeviceUID))
            }
            stableIdentityRead = finalObjects == objects && finalIdentities == rawIdentities
        } catch { stableIdentityRead = false }
        try lease?.check()
        return CoreAudioSnapshot(devices: devices, currentDeviceID: identities[current],
                                 systemSoundDeviceID: identities[sound], warnings: warnings,
                                 confirmedDeviceObjects: uniqueObjects,
                                 discovery: CoreAudioIdentityInventory.discovery(rawIdentities,
                                    complete: completeIdentityRead && stableIdentityRead),
                                 isOutputInventoryComplete: completeOutputRead,
                                 serviceGeneration: lease?.id)
    }

    /// Narrow boundary used by the volume extension on this same actor.
    func volumeObject(uid: String) throws -> AudioObjectID {
        try checkVolumeRunning()
        return try volumeIO.outputDevice(uid: uid)
    }

    func checkVolumeRunning() throws {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
    }

    func submitVolumeMutation(permit: AudioMutationPermit, serviceLease: AudioServiceEpoch.Lease? = nil,
                              _ operation: () -> OSStatus) throws -> OSStatus {
        try checkVolumeRunning()
        let lease = try serviceLease ?? AudioServiceOperation.capture(from: serviceEpoch)
        var result = OSStatus(noErr)
        guard shutdownSignal.performIfRunning(permit: permit, servicePermit: lease?.permit, { result = operation() }) else { throw CancellationError() }
        return result
    }

    func drainVolumeSubmissions() async { await shutdownSignal.drainSubmissions() }

    func performVolumeListenerRegistration(lease: AudioServiceEpoch.Lease?, _ install: () -> Void) -> Bool {
        shutdownSignal.performIfRunning(servicePermit: lease?.permit, install)
    }

    func builtInSpeaker() async throws -> AudioDevice {
        let lease = try AudioServiceOperation.capture(from: serviceEpoch)
        let inventory = try await BuiltInSpeakerSelection.readStableInventory(
            read: { try self.builtInSpeakerInventory() },
            checkRunning: { try self.shutdownSignal.checkRunning(); try lease?.check() }
        )
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        try lease?.check()
        return try BuiltInSpeakerSelection.resolve(inventory.candidates, deviceUIDs: inventory.identities.map(\.uid))
    }

    private func builtInSpeakerInventory() throws -> BuiltInSpeakerSelection.Inventory {
        var identities: [BuiltInSpeakerSelection.DeviceIdentity] = []
        var candidates: [BuiltInSpeakerSelection.Candidate] = []
        for object in try deviceIDs().sorted() {
            try Task.checkCancellation()
            try shutdownSignal.checkRunning()
            let uid = try string(object, kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty else { throw AudioServiceError.ambiguousIdentity }
            let type = try scalar(object, kAudioDevicePropertyTransportType)
            identities.append(BuiltInSpeakerSelection.DeviceIdentity(objectID: object, uid: uid, transportType: type))
            guard type == kAudioDeviceTransportTypeBuiltIn else { continue }
            let channels = try outputChannelCount(object)
            guard channels > 0 else { continue }
            let alive = try scalar(object, kAudioDevicePropertyDeviceIsAlive) == 1
            let eligible = try scalar(object, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput) == 1
            let hidden = try scalar(object, kAudioDevicePropertyIsHidden) != 0
            guard alive, eligible, !hidden, channels > 0 else { continue }
            let streams = try objectIDs(object, selector: kAudioDevicePropertyStreams,
                                        scope: kAudioObjectPropertyScopeOutput, operation: String(localized: "service.output_streams", defaultValue: "Output audio streams")).sorted().map { stream in
                BuiltInSpeakerSelection.Stream(objectID: stream,
                                               direction: try scalar(stream, kAudioStreamPropertyDirection),
                                               terminalType: try scalar(stream, kAudioStreamPropertyTerminalType))
            }
            // IsActive means currently doing IO. An idle speaker remains a valid
            // destination while AirPlay is playing, so it is not an identity gate.
            let name = try string(object, kAudioObjectPropertyName)
            candidates.append(BuiltInSpeakerSelection.Candidate(
                objectID: object,
                device: AudioDevice(id: "hal:\(uid)", name: name, transport: .speaker, backend: .coreAudio(uid: uid)),
                transportType: type, alive: alive, canBeDefaultOutput: eligible,
                hidden: hidden, outputChannelCount: channels, streams: streams
            ))
        }
        return BuiltInSpeakerSelection.Inventory(identities: identities, candidates: candidates)
    }

    func select(uid: String) throws {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        let lease = try AudioServiceOperation.capture(from: serviceEpoch)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        try CoreAudioOutputSelection.submit(uid: uid,
            deviceIDs: { try self.deviceIDs() },
            readUID: { try self.string($0, kAudioDevicePropertyDeviceUID) },
            readAvailability: { object in
                let eligible: UInt32 = try self.scalar(object, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                                       scope: kAudioObjectPropertyScopeOutput)
                let alive: UInt32 = try self.scalar(object, kAudioDevicePropertyDeviceIsAlive)
                return (eligible != 0, alive != 0)
            }, checkSettable: {
                var settable = DarwinBoolean(false)
                try self.check(AudioObjectIsPropertySettable(self.system, &address, &settable), String(localized: "service.check_output_capability", defaultValue: "Check output switching capability"))
                guard settable.boolValue else { throw AudioServiceError.unavailable(String(localized: "audio.output_change_disallowed", defaultValue: "The system does not currently allow changing the default output.")) }
            }, checkRunning: {
                try Task.checkCancellation()
                try self.shutdownSignal.checkRunning()
                try lease?.check()
            }, performIfRunning: { operation in
                self.shutdownSignal.performIfRunning(servicePermit: lease?.permit, operation)
            }, write: { object in
                var value = object
                try self.check(AudioObjectSetPropertyData(self.system, &address, 0, nil,
                    UInt32(MemoryLayout.size(ofValue: value)), &value), String(localized: "service.request_output_switch", defaultValue: "Request output switch"))
            })
    }

    func observeChanges(_ changed: @escaping @Sendable () -> Void) throws {
        try installDirectoryObservers { _ in changed() }
    }

    func observeEvents(_ changed: @escaping @Sendable (AudioHardwareEvent) -> Void) async throws {
        try installDirectoryObservers(changed)
    }

    private func installDirectoryObservers(_ changed: @escaping @Sendable (AudioHardwareEvent) -> Void) throws {
        try Task.checkCancellation()
        try shutdownSignal.checkRunning()
        let lease = try AudioServiceOperation.capture(from: serviceEpoch)
        discardResetObserversIfNeeded()
        guard removeObservers() else {
            throw AudioServiceError.unavailable(String(localized: "audio.listener_cleanup_pending", defaultValue: "Audio listener cleanup is not yet complete. Refreshing periodically."))
        }
        let properties: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            kAudioHardwarePropertyServiceRestarted,
        ]
        do {
            for selector in properties {
                try Task.checkCancellation()
                try shutdownSignal.checkRunning()
                let property = address(selector)
                try lease?.check()
                let delivery = AudioVolumeListenerDelivery { [serviceEpoch] in
                    if selector == kAudioHardwarePropertyServiceRestarted, let generation = serviceEpoch?.capture().id {
                        changed(.serviceRestarted(generation))
                    } else { changed(.changed) }
                }
                let token = makeDirectoryListener(system, property, .global(qos: .utility)) { [serviceEpoch] _, _ in
                    delivery.signal {
                        if selector == kAudioHardwarePropertyServiceRestarted {
                            guard let id = lease?.id else { return false }
                            return serviceEpoch?.reset(ifCurrent: id) != nil
                        }
                        return lease?.permit.isActive != false
                    }
                }
                var status = noErr
                guard shutdownSignal.performIfRunning(servicePermit: lease?.permit, {
                    status = token.registerListener()
                }) else { delivery.close(); throw CancellationError() }
                guard status == noErr else {
                    delivery.close()
                    throw AudioServiceError.system(operation: String(localized: "service.listen_audio_status", defaultValue: "Listen for audio changes"), status: status)
                }
                discardResetObserversIfNeeded()
                observers.append(DirectoryObserver(token: token, delivery: delivery))
                // A registration returning across reset may have reached the
                // new service. Retain its exact token for real removal.
                observerGeneration = lease?.permit.isActive == false ? serviceEpoch?.capture().id : lease?.id
            }
            try lease?.check()
        } catch {
            discardResetObserversIfNeeded()
            _ = removeObservers()
            throw error
        }
    }

    func stopObserving() async {
        await shutdownSignal.drainSubmissions()
        _ = removeObservers()
    }

    @discardableResult private func removeObservers() -> Bool {
        discardResetObserversIfNeeded()
        for registration in observers { registration.delivery.close() }
        observers = observers.filter { registration in
            let status = registration.token.removeListener()
            return status != noErr && status != kAudioHardwareBadObjectError
        }
        return observers.isEmpty
    }

    /// A service reset has already destroyed the remote registrations. Retire
    /// their closed local tokens without removing against reused object IDs.
    private func discardResetObserversIfNeeded() {
        guard let observerGeneration, observerGeneration != serviceEpoch?.capture().id else { return }
        for registration in observers { registration.delivery.close() }
        observers.removeAll()
        self.observerGeneration = nil
    }

    nonisolated func beginShutdown() { shutdownSignal.begin(); serviceEpoch?.close() }

    private func deviceIDs() throws -> [AudioObjectID] {
        try objectIDs(system, selector: kAudioHardwarePropertyDevices, operation: String(localized: "service.device_list", defaultValue: "Device list"))
    }

    private func objectIDs(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                           operation: String) throws -> [AudioObjectID] {
        var property = address(selector, scope: scope)
        // Retry a size/read race when hardware is plugged or removed between the calls.
        for attempt in 0..<3 {
            var size: UInt32 = 0
            try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), String(localized: "service.read_length", defaultValue: "Read \(operation) length"))
            guard size > 0 else { return [] }
            guard Int(size) % MemoryLayout<AudioObjectID>.stride == 0 else {
                throw AudioServiceError.system(operation: String(localized: "service.invalid_length", defaultValue: "Invalid \(operation) length"), status: kAudioHardwareBadPropertySizeError)
            }
            let allocatedSize = size
            var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
            let status = values.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
            }
            if status == noErr {
                guard size <= allocatedSize, Int(size) % MemoryLayout<AudioObjectID>.stride == 0 else {
                    throw AudioServiceError.system(operation: String(localized: "service.invalid_data_length", defaultValue: "Invalid \(operation) data length"), status: kAudioHardwareBadPropertySizeError)
                }
                return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
            }
            if attempt == 2 { try check(status, String(localized: "service.read_operation", defaultValue: "Read \(operation)")) }
        }
        return []
    }

    private func scalar(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        var property = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), String(localized: "service.read_audio_property", defaultValue: "Read audio property"))
        guard size == MemoryLayout<UInt32>.size else {
            throw AudioServiceError.system(operation: String(localized: "service.audio_property_invalid_length", defaultValue: "Invalid audio property length"), status: kAudioHardwareBadPropertySizeError)
        }
        return value
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
        }
        try check(status, String(localized: "service.read_device_name_or_id", defaultValue: "Read device name or identifier"))
        guard let value else { throw AudioServiceError.unavailable(String(localized: "audio.device_name_unreadable", defaultValue: "The device name or identifier could not be read.")) }
        return value.takeRetainedValue() as String
    }

    private func outputChannelCount(_ object: AudioObjectID) throws -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), String(localized: "service.read_output_channels", defaultValue: "Read output channels"))
        let bufferOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard size >= bufferOffset else { return 0 }
        let allocatedSize = size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, storage), String(localized: "service.read_output_channels", defaultValue: "Read output channels"))
        let pointer = storage.assumingMemoryBound(to: AudioBufferList.self)
        guard size <= allocatedSize, size >= bufferOffset,
              bufferOffset + Int(pointer.pointee.mNumberBuffers) * MemoryLayout<AudioBuffer>.stride <= size else {
            throw AudioServiceError.system(operation: String(localized: "service.output_channels_invalid_length", defaultValue: "Invalid output channel data length"), status: kAudioHardwareBadPropertySizeError)
        }
        let list = UnsafeMutableAudioBufferListPointer(pointer)
        return list.reduce(0) { $0 + $1.mNumberChannels }
    }

    /// These optional reads never contribute to source health or capability.
    /// A driver without an icon/model still produces a normal usable row.
    private func deviceIcon(_ object: AudioObjectID, uid: String, name: String, transportType: UInt32,
                            uniqueObject: Bool, rawUIDs: [String]) -> AudioDeviceIcon {
        guard uniqueObject else { return .fallback }
        let modelValue = optionalObjectProperty(object, kAudioDevicePropertyModelUID)
        let firstModel = modelValue.flatMap { CFGetTypeID($0) == CFStringGetTypeID() ? ($0 as? String) : nil }
        let modelReadback = optionalObjectProperty(object, kAudioDevicePropertyModelUID)
            .flatMap { CFGetTypeID($0) == CFStringGetTypeID() ? ($0 as? String) : nil }
        let model = firstModel == modelReadback ? firstModel : nil
        let iconValue = optionalObjectProperty(object, kAudioDevicePropertyIcon)
        let imageURL = iconValue.flatMap { CFGetTypeID($0) == CFURLGetTypeID() ? ($0 as? URL) : nil }
            .flatMap { $0.isFileURL ? $0 : nil }
        let runtime = THPrivateAudioRuntime.system()
        let modelSymbol = model.flatMap { THAudioDeviceSymbolForModelIdentifier($0, runtime) }
        let firstStreams = try? iconOutputStreams(object)
        let secondStreams = try? iconOutputStreams(object)
        let streams = firstStreams == secondStreams ? (firstStreams ?? []) : []
        let candidate = BuiltInSpeakerSelection.Candidate(objectID: object,
            device: AudioDevice(id: "hal:\(uid)", name: name, transport: .speaker, backend: .coreAudio(uid: uid)),
            transportType: transportType,
            alive: (try? scalar(object, kAudioDevicePropertyDeviceIsAlive)) == 1,
            canBeDefaultOutput: (try? scalar(object, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                           scope: kAudioObjectPropertyScopeOutput)) == 1,
            hidden: (try? scalar(object, kAudioDevicePropertyIsHidden)) != 0,
            outputChannelCount: (try? outputChannelCount(object)) ?? 0, streams: streams)
        let builtIn = (try? BuiltInSpeakerSelection.resolve([candidate], deviceUIDs: rawUIDs)) != nil
        let hostModel = builtIn ? CoreAudioDeviceIcon.currentHostModelIdentifier() : nil
        let hostSymbol = hostModel.flatMap { THAudioDeviceSymbolForModelIdentifier($0, runtime) }
        // Optional presentation evidence only: failed/changing metadata withholds
        // the generic connection glyph without affecting the usable HAL row.
        // Do not turn unreadable or conflicting terminals into "unspecified".
        let transportReadback: UInt32? = try? scalar(object, kAudioDevicePropertyTransportType)
        let iconTransport = transportReadback == transportType && firstStreams != nil && firstStreams == secondStreams
            ? transportType : nil
        guard (try? string(object, kAudioDevicePropertyDeviceUID)) == uid else { return .fallback }
        return CoreAudioDeviceIcon.resolve(modelIdentifier: model, modelSymbol: modelSymbol,
            verifiedBuiltInSpeaker: builtIn, hostModelIdentifier: hostModel, hostModelSymbol: hostSymbol,
            terminalTypes: streams.map(\.terminalType), imageFileURL: imageURL,
            confirmedTransportType: iconTransport)
    }

    private func iconOutputStreams(_ object: AudioObjectID) throws -> [BuiltInSpeakerSelection.Stream] {
        let streamIDs = try objectIDs(object, selector: kAudioDevicePropertyStreams,
                                      scope: kAudioObjectPropertyScopeOutput, operation: String(localized: "service.output_terminal_icon", defaultValue: "Output terminal icon")).sorted()
        guard Set(streamIDs).count == streamIDs.count else { throw AudioServiceError.ambiguousIdentity }
        return try streamIDs.map { stream in
            let direction = try scalar(stream, kAudioStreamPropertyDirection)
            guard direction == 0 else { throw AudioServiceError.ambiguousIdentity }
            return BuiltInSpeakerSelection.Stream(objectID: stream, direction: direction,
                terminalType: try scalar(stream, kAudioStreamPropertyTerminalType))
        }
    }

    private func optionalObjectProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> CFTypeRef? {
        var property = address(selector)
        guard AudioObjectHasProperty(object, &property) else { return nil }
        var value: Unmanaged<CFTypeRef>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
        }
        // The Copy-style HAL property owns its returned object even when the
        // driver reports a malformed size/status after populating the pointer.
        let objectValue = value?.takeRetainedValue()
        guard status == noErr, size == MemoryLayout.size(ofValue: value) else { return nil }
        return objectValue
    }

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw AudioServiceError.system(operation: operation, status: status) }
    }

    private func transport(_ value: UInt32) -> AudioTransport {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: .speaker
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: .display
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeAirPlay: .airplay
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: .virtual
        default: .unknown
        }
    }
}
