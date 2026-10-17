import CoreAudio
import AudioToolbox
import Foundation

/// A failed listener removal keeps a retry handle, but never keeps a live
/// callback into the Store. A callback already copied may finish as invalidation.
final class AudioVolumeListenerDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    init(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }
    func signal() { let callback = lock.withLock { self.callback }; callback?() }
    func signal(if admitted: () -> Bool) {
        let callback = lock.withLock { self.callback != nil && admitted() ? self.callback : nil }
        callback?()
    }
    func close() { lock.withLock { callback = nil } }
}

/// Storage belongs to CoreAudioService's actor. It never shares the directory
/// observer array; clearing/retrying either family leaves the other untouched.
struct CoreAudioVolumeObservationState {
    struct Registration {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let token: THVolumeListenerToken
        let delivery: AudioVolumeListenerDelivery
    }
    var registrations: [Registration] = []
    var serviceGeneration: UUID?
}

struct AudioVolumePropertyEvidence: Equatable, Sendable {
    let value: Float
    let writable: Bool
}

/// The fallback is explicitly an implementation gap until balance and topology
/// can be proven. It is never mislabeled as an unsupported system device.
enum AudioVolumeCapabilityPolicy {
    static func choose(main: AudioVolumePropertyEvidence?, virtualMain: AudioVolumePropertyEvidence?,
                       channels: [UInt32: AudioVolumePropertyEvidence]) -> (Float?, AudioVolumeCapability) {
        if let main { return (main.value, main.writable ? .writable(.main) : .unavailable(.readOnly)) }
        if let virtualMain { return (virtualMain.value, .unavailable(virtualMain.writable ? .implementationGap : .readOnly)) }
        if !channels.isEmpty {
            let value = channels.values.map(\.value).max()
            return (value, .unavailable(channels.values.contains(where: \.writable) ? .implementationGap : .readOnly))
        }
        return (nil, .unavailable(.unsupported))
    }
}

extension CoreAudioService: AudioVolumeProviding, AudioVolumeTransactionAccess {
    func readVolume(for target: AudioVolumeTarget) throws -> AudioVolumeSnapshot {
        try inspectVolume(for: target).snapshot
    }

    func setVolume(_ value: Float, for target: AudioVolumeTarget, permit: AudioMutationPermit) async throws -> AudioVolumeWriteResult {
        try checkVolumeRunning()
        let lease = try volumeServiceLease(for: target)
        return try await AudioServiceOperation.$lease.withValue(lease) {
            try await AudioVolumeTransaction.run(value: value, target: target, permit: permit, access: self)
        }
    }

    func inspectVolume(for target: AudioVolumeTarget, expectation: AudioVolumeWriteExpectation? = nil) throws -> AudioVolumeInspection {
        try Task.checkCancellation()
        try checkVolumeRunning()
        let lease = try volumeServiceLease(for: target)
        let object = try volumeObject(uid: target.uid)
        let main = try volumeFloat(object, selector: kAudioDevicePropertyVolumeScalar)
        var virtualMain: AudioVolumePropertyEvidence?
        var channels: [UInt32: AudioVolumePropertyEvidence] = [:]
        if main == nil {
            virtualMain = try volumeFloat(object, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            if virtualMain == nil {
                for element in try volumeOutputElements(object) {
                    channels[element] = try volumeFloat(object, selector: kAudioDevicePropertyVolumeScalar, element: element)
                }
            }
        }
        var (value, capability) = AudioVolumeCapabilityPolicy.choose(main: main, virtualMain: virtualMain, channels: channels)
        var actualDecibels: Float?
        if let expectation, let equivalent = expectation.equivalent {
            try validateVolumeExpectation(expectation, object: object)
            let firstDecibels = try? volumeIO.decibels(object)
            guard let firstScalar = main,
                  let lastScalar = try volumeFloat(object, selector: kAudioDevicePropertyVolumeScalar) else {
                throw AudioVolumeIssue.invalidReadback
            }
            let lastDecibels = try? volumeIO.decibels(object)
            // A changing pair cannot certify an equivalent target. Keep the
            // latest scalar visible, but omit dB evidence until a stable read.
            value = lastScalar.value
            capability = lastScalar.writable ? .writable(.main) : .unavailable(.readOnly)
            if AudioVolumeTransaction.matches(firstScalar.value, requested: lastScalar.value),
               let firstDecibels, let lastDecibels,
               equivalent.range.contains(firstDecibels), equivalent.range.contains(lastDecibels),
               AudioVolumeTransaction.matchesDecibels(firstDecibels, expected: lastDecibels) {
                actualDecibels = lastDecibels
            }
            try validateVolumeExpectation(expectation, object: object)
        }
        // Keep mute observation after the extra conversion/scalar/dB reads so
        // the returned joint state does not reuse an earlier mute value.
        let (mute, canUnmute) = volumeMute(object)
        // Detect removal/replacement during a compound property read.
        guard try volumeObject(uid: target.uid) == object else { throw AudioVolumeIssue.identityChanged }
        try lease?.check()
        return AudioVolumeInspection(objectID: object, snapshot: AudioVolumeSnapshot(target: target, value: value,
            capability: capability, mute: mute, canUnmute: canUnmute), decibels: actualDecibels)
    }

    func prepareWriteExpectation(_ value: Float, for target: AudioVolumeTarget,
                                 expectedObject: UInt32) throws -> AudioVolumeWriteExpectation {
        guard AudioVolumeScalar.validScalar(value) else { throw AudioVolumeIssue.invalidValue }
        guard try volumeObject(uid: target.uid) == expectedObject else { throw AudioVolumeIssue.identityChanged }
        let equivalent = volumeEquivalentTarget(object: expectedObject, requested: value)
        guard try volumeObject(uid: target.uid) == expectedObject else { throw AudioVolumeIssue.identityChanged }
        return AudioVolumeWriteExpectation(requestedScalar: value, equivalent: equivalent)
    }

    func submitVolume(_ expectation: AudioVolumeWriteExpectation, for target: AudioVolumeTarget,
                      expectedObject: UInt32, permit: AudioMutationPermit) throws {
        let lease = try volumeServiceLease(for: target)
        guard AudioVolumeScalar.validScalar(expectation.requestedScalar) else { throw AudioVolumeIssue.invalidValue }
        let live = try inspectVolume(for: target, expectation: expectation)
        guard live.objectID == expectedObject else { throw AudioVolumeIssue.identityChanged }
        guard live.snapshot.capability == .writable(.main) else { throw live.snapshot.capability.issue ?? .implementationGap }
        // The driver receives the user's original scalar, never a guessed or
        // substituted target derived from an observed readback.
        try writeVolume(expectation.requestedScalar, object: expectedObject, permit: permit, lease: lease)
    }

    func submitVolumeAfterUnmute(_ expectation: AudioVolumeWriteExpectation, for target: AudioVolumeTarget, expected: AudioVolumeInspection,
                                permit: AudioMutationPermit) throws {
        let lease = try volumeServiceLease(for: target)
        let value = expectation.requestedScalar
        guard AudioVolumeScalar.validScalar(value), value > 0 else { throw AudioVolumeIssue.invalidValue }
        guard expected.snapshot.target == target else { throw AudioVolumeIssue.identityChanged }
        let live = try inspectVolume(for: target, expectation: expectation)
        guard live.objectID == expected.objectID, live.snapshot.target == expected.snapshot.target else {
            throw AudioVolumeIssue.identityChanged
        }
        guard live.snapshot.capability == .writable(.main) else { throw live.snapshot.capability.issue ?? .implementationGap }
        guard live.snapshot.mute == .unmuted,
              let expectedValue = expected.snapshot.value,
              live.snapshot.value.map({ AudioVolumeTransaction.matches($0, requested: expectedValue) }) == true else {
            throw AudioVolumeIssue.unconfirmed
        }
        if expectation.equivalent != nil {
            guard let expectedDecibels = expected.decibels, let liveDecibels = live.decibels,
                  AudioVolumeTransaction.matchesDecibels(liveDecibels, expected: expectedDecibels) else {
                throw AudioVolumeIssue.unconfirmed
            }
        }
        try writeVolume(value, object: expected.objectID, permit: permit, lease: lease)
    }

    private func writeVolume(_ value: Float, object: AudioObjectID, permit: AudioMutationPermit,
                             lease: AudioServiceEpoch.Lease?) throws {
        let status = try submitVolumeMutation(permit: permit, serviceLease: lease) {
            volumeIO.setScalar(object, value: value)
        }
        guard status == noErr else { throw AudioVolumeIssue.writeFailed(status) }
    }

    func submitUnmute(for target: AudioVolumeTarget, expectedObject: UInt32, expectation: AudioVolumeUnmuteExpectation,
                      permit: AudioMutationPermit) throws {
        let lease = try volumeServiceLease(for: target)
        guard AudioVolumeScalar.validScalar(expectation.requestedValue), expectation.requestedValue > 0 else {
            throw AudioVolumeIssue.invalidValue
        }
        if case let .unconfirmedMutedVolume(_, observedValue) = expectation {
            guard AudioVolumeScalar.validScalar(observedValue) else { throw AudioVolumeIssue.invalidReadback }
        }
        let initial = try volumeMuteEvidence(expectedObject)
        if case .unconfirmedMutedVolume = expectation {
            guard initial.state.isAudiblyMuted else { throw AudioVolumeIssue.unconfirmed }
            guard initial.canUnmute else { throw AudioVolumeIssue.stillMuted }
        }
        for element in initial.controls.keys.sorted() where initial.controls[element]?.value == 1 {
            let live = try inspectVolume(for: target, expectation: expectation.write)
            guard live.objectID == expectedObject else { throw AudioVolumeIssue.identityChanged }
            switch expectation {
            case let .confirmedVolume(write):
                guard write.confirms(live) else { throw AudioVolumeIssue.unconfirmed }
            case let .unconfirmedMutedVolume(_, observedValue):
                guard live.snapshot.value.map({
                    AudioVolumeTransaction.matches($0, requested: observedValue)
                }) == true else { throw AudioVolumeIssue.unconfirmed }
            }
            if case .unconfirmedMutedVolume = expectation {
                guard live.snapshot.mute.isAudiblyMuted else { throw AudioVolumeIssue.unconfirmed }
                guard live.snapshot.canUnmute else { throw AudioVolumeIssue.stillMuted }
            }
            let mute = try volumeMuteEvidence(expectedObject)
            guard mute.elements == initial.elements, mute.controls.keys.sorted() == initial.controls.keys.sorted() else {
                throw AudioVolumeIssue.identityChanged
            }
            if case .unconfirmedMutedVolume = expectation {
                guard mute.state.isAudiblyMuted else { throw AudioVolumeIssue.unconfirmed }
                guard mute.canUnmute else { throw AudioVolumeIssue.stillMuted }
            }
            guard mute.canUnmute || !mute.state.isAudiblyMuted else { throw AudioVolumeIssue.stillMuted }
            guard mute.controls[element]?.value == 1 else { continue }
            try validateVolumeExpectation(expectation.write, object: expectedObject)
            guard try volumeObject(uid: target.uid) == expectedObject else { throw AudioVolumeIssue.identityChanged }
            let status = try submitVolumeMutation(permit: permit, serviceLease: lease) {
                volumeIO.setMute(expectedObject, element: element, value: 0)
            }
            guard status == noErr else { throw AudioVolumeIssue.writeFailed(status) }
        }
    }

    func observeVolumeChanges(targets: [AudioVolumeTarget], changed: @escaping @Sendable () -> Void) throws {
        try Task.checkCancellation()
        try checkVolumeRunning()
        let lease = try AudioServiceOperation.capture(from: serviceEpoch)
        discardResetVolumeObserversIfNeeded()
        guard removeVolumeObservers() else { throw AudioVolumeIssue.listenerUnavailable }
        var seen = Set<AudioObjectID>()
        do {
            for target in targets {
                _ = try volumeServiceLease(for: target)
                try Task.checkCancellation()
                try checkVolumeRunning()
                let object = try volumeObject(uid: target.uid)
                guard seen.insert(object).inserted else { continue }
                var addresses = [
                    volumeAddress(kAudioDevicePropertyVolumeScalar),
                    volumeAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                    volumeAddress(kAudioDevicePropertyMute),
                    volumeAddress(kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal),
                    volumeAddress(kAudioObjectPropertyControlList, scope: kAudioObjectPropertyScopeGlobal),
                    volumeAddress(kAudioDevicePropertyStreamConfiguration),
                ]
                for element in try volumeOutputElements(object) {
                    addresses.append(volumeAddress(kAudioDevicePropertyVolumeScalar, element: element))
                    addresses.append(volumeAddress(kAudioDevicePropertyMute, element: element))
                }
                for address in addresses where volumeIO.hasProperty(object, address: address) {
                    try lease?.check()
                    var installationError: (any Error)?
                    guard performVolumeListenerRegistration(lease: lease, {
                        do {
                            let registration = try volumeIO.addListener(object, address: address) {
                                guard lease?.permit.isActive != false else { return }
                                changed()
                            }
                            discardResetVolumeObserversIfNeeded()
                            volumeObservationState.registrations.append(registration)
                            volumeObservationState.serviceGeneration = lease?.permit.isActive == false ? serviceEpoch?.capture().id : lease?.id
                        } catch { installationError = error }
                    }) else { throw CancellationError() }
                    if let installationError { throw installationError }
                }
            }
            try lease?.check()
        } catch {
            discardResetVolumeObserversIfNeeded()
            _ = removeVolumeObservers()
            throw error
        }
    }

    func stopObservingVolume() async {
        await drainVolumeSubmissions()
        _ = removeVolumeObservers()
    }

    @discardableResult private func removeVolumeObservers() -> Bool {
        discardResetVolumeObserversIfNeeded()
        volumeObservationState.registrations = volumeObservationState.registrations.filter { registration in
            registration.delivery.close()
            let status = volumeIO.removeListener(registration)
            return status != noErr && status != kAudioHardwareBadObjectError
        }
        return volumeObservationState.registrations.isEmpty
    }

    private func discardResetVolumeObserversIfNeeded() {
        guard let generation = volumeObservationState.serviceGeneration,
              generation != serviceEpoch?.capture().id else { return }
        for registration in volumeObservationState.registrations { registration.delivery.close() }
        volumeObservationState.registrations.removeAll()
        volumeObservationState.serviceGeneration = nil
    }

    private func volumeServiceLease(for target: AudioVolumeTarget) throws -> AudioServiceEpoch.Lease? {
        let lease = try AudioServiceOperation.capture(from: serviceEpoch)
        if let expected = target.serviceGeneration, expected != lease?.id { throw AudioVolumeIssue.identityChanged }
        return lease
    }

    private func volumeAddress(_ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
                               element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func volumeFloat(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                             element: UInt32 = kAudioObjectPropertyElementMain) throws -> AudioVolumePropertyEvidence? {
        try volumeIO.scalar(object, selector: selector, element: element)
    }

    private func validateVolumeExpectation(_ expectation: AudioVolumeWriteExpectation, object: AudioObjectID) throws {
        guard let equivalent = expectation.equivalent else { return }
        guard volumeEquivalentTarget(object: object, requested: expectation.requestedScalar) == equivalent else {
            // A prepared mapping never changes under an existing request. It
            // must not be downgraded to recovery or replaced after a side effect.
            throw AudioVolumeIssue.unconfirmed
        }
    }

    private func volumeEquivalentTarget(object: AudioObjectID, requested: Float) -> AudioVolumeEquivalentTarget? {
        guard requested > 0, AudioVolumeScalar.validScalar(requested) else { return nil }
        do {
            guard let first = try volumeConversionCandidate(object: object, requested: requested),
                  let second = try volumeConversionCandidate(object: object, requested: requested),
                  first == second else { return nil }
            return first
        } catch {
            // Optional conversion failures leave exact-scalar confirmation
            // available. A previously prepared mapping is rejected by its caller.
            return nil
        }
    }

    private func volumeConversionCandidate(object: AudioObjectID, requested: Float) throws -> AudioVolumeEquivalentTarget? {
        guard let range = try volumeIO.decibelRange(object), range.isValid,
              let decibels = try volumeIO.scalarToDecibels(object, value: requested), range.contains(decibels),
              let scalar = try volumeIO.decibelsToScalar(object, value: decibels), AudioVolumeScalar.validScalar(scalar),
              !AudioVolumeTransaction.matches(scalar, requested: requested),
              let canonicalDecibels = try volumeIO.scalarToDecibels(object, value: scalar), range.contains(canonicalDecibels),
              AudioVolumeTransaction.matchesDecibels(canonicalDecibels, expected: decibels),
              let canonicalScalar = try volumeIO.decibelsToScalar(object, value: canonicalDecibels),
              AudioVolumeTransaction.matches(canonicalScalar, requested: scalar) else { return nil }
        return AudioVolumeEquivalentTarget(scalar: scalar, decibels: decibels, range: range)
    }

    private func volumeMute(_ object: AudioObjectID) -> (AudioVolumeMuteState, Bool) {
        do {
            let evidence = try volumeMuteEvidence(object)
            return (evidence.state, evidence.canUnmute)
        } catch { return (.unknown, false) }
    }

    private struct MuteEvidence {
        let elements: [UInt32]
        let controls: [UInt32: AudioVolumeMuteEvidence]
        var state: AudioVolumeMuteState {
            guard !controls.isEmpty else { return .unsupported }
            if controls[0]?.value == 1 { return .muted }
            let muted = elements.filter { controls[$0]?.value == 1 }.count
            if muted == 0 { return .unmuted }
            return muted == elements.count ? .muted : .mixed
        }
        var canUnmute: Bool {
            state.isAudiblyMuted && controls.values.filter { $0.value == 1 }.allSatisfy(\.writable)
        }
    }

    private func volumeMuteEvidence(_ object: AudioObjectID) throws -> MuteEvidence {
        let elements = try volumeOutputElements(object).sorted()
        guard !elements.isEmpty, Set(elements).count == elements.count, !elements.contains(0) else {
            throw AudioVolumeIssue.invalidReadback
        }
        var controls: [UInt32: AudioVolumeMuteEvidence] = [:]
        for element in [0] + elements {
            if let evidence = try volumeIO.mute(object, element: element) {
                guard evidence.value <= 1 else { throw AudioVolumeIssue.invalidReadback }
                controls[element] = evidence
            }
        }
        guard try volumeOutputElements(object).sorted() == elements else { throw AudioVolumeIssue.identityChanged }
        return MuteEvidence(elements: elements, controls: controls)
    }

    private func volumeOutputElements(_ object: AudioObjectID) throws -> [UInt32] {
        try volumeIO.outputElements(object)
    }
}
