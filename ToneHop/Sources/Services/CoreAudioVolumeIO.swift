import CoreAudio
import Foundation

struct AudioVolumeMuteEvidence: Equatable, Sendable {
    let value: UInt32
    let writable: Bool
}

/// Synchronous calls are made exclusively by the existing CoreAudioService
/// actor. Mutations are always wrapped by that actor's original admission gate.
protocol CoreAudioVolumeIO: Sendable {
    func outputDevice(uid: String) throws -> AudioObjectID
    func scalar(_ object: AudioObjectID, selector: AudioObjectPropertySelector, element: UInt32) throws -> AudioVolumePropertyEvidence?
    func decibelRange(_ object: AudioObjectID) throws -> AudioVolumeDecibelRange?
    func decibels(_ object: AudioObjectID) throws -> Float?
    func scalarToDecibels(_ object: AudioObjectID, value: Float) throws -> Float?
    func decibelsToScalar(_ object: AudioObjectID, value: Float) throws -> Float?
    func mute(_ object: AudioObjectID, element: UInt32) throws -> AudioVolumeMuteEvidence?
    func outputElements(_ object: AudioObjectID) throws -> [UInt32]
    func hasProperty(_ object: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool
    func setScalar(_ object: AudioObjectID, value: Float) -> OSStatus
    func setMute(_ object: AudioObjectID, element: UInt32, value: UInt32) -> OSStatus
    func addListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                     changed: @escaping @Sendable () -> Void) throws -> CoreAudioVolumeObservationState.Registration
    func removeListener(_ registration: CoreAudioVolumeObservationState.Registration) -> OSStatus
}

extension CoreAudioVolumeIO {
    // Optional driver evidence. Missing conversion properties never fabricate a
    // quantization step or change the existing exact-scalar write contract.
    func decibelRange(_ object: AudioObjectID) throws -> AudioVolumeDecibelRange? { nil }
    func decibels(_ object: AudioObjectID) throws -> Float? { nil }
    func scalarToDecibels(_ object: AudioObjectID, value: Float) throws -> Float? { nil }
    func decibelsToScalar(_ object: AudioObjectID, value: Float) throws -> Float? { nil }
}

struct SystemCoreAudioVolumeIO: CoreAudioVolumeIO {
    func outputDevice(uid: String) throws -> AudioObjectID {
        guard !uid.isEmpty else { throw AudioVolumeIssue.identityUnconfirmed }
        var address = property(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        let bytes = try data(object: AudioObjectID(kAudioObjectSystemObject), address: &address)
        guard bytes.count % MemoryLayout<AudioObjectID>.stride == 0 else { throw AudioVolumeIssue.invalidReadback }
        let devices = bytes.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: MemoryLayout<AudioObjectID>.stride).map {
                raw.loadUnaligned(fromByteOffset: $0, as: AudioObjectID.self)
            }
        }
        var matches: [AudioObjectID] = []
        for object in devices {
            var uidAddress = property(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
            var string: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout.size(ofValue: string))
            let status = AudioObjectGetPropertyData(object, &uidAddress, 0, nil, &size, &string)
            guard status == noErr, size == MemoryLayout.size(ofValue: string), let string else {
                if let string { string.release() }
                throw AudioVolumeIssue.readFailed(status == noErr ? kAudioHardwareBadPropertySizeError : status)
            }
            if string.takeRetainedValue() as String == uid { matches.append(object) }
        }
        guard matches.count == 1, let object = matches.first else {
            throw matches.isEmpty ? AudioVolumeIssue.notConnected : AudioVolumeIssue.identityUnconfirmed
        }
        let alive = try uint32(object, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal)
        guard alive == 1, !(try outputElements(object)).isEmpty else { throw AudioVolumeIssue.notConnected }
        return object
    }

    func scalar(_ object: AudioObjectID, selector: AudioObjectPropertySelector, element: UInt32) throws -> AudioVolumePropertyEvidence? {
        var address = property(selector, element: element)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioVolumeIssue.readFailed(status) }
        guard size == MemoryLayout<Float32>.size, AudioVolumeScalar.validScalar(value) else { throw AudioVolumeIssue.invalidReadback }
        return AudioVolumePropertyEvidence(value: value, writable: try writable(object, address: &address))
    }

    func decibelRange(_ object: AudioObjectID) throws -> AudioVolumeDecibelRange? {
        var address = property(kAudioDevicePropertyVolumeRangeDecibels)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioVolumeIssue.readFailed(status) }
        guard size == MemoryLayout<AudioValueRange>.size else { throw AudioVolumeIssue.invalidReadback }
        return AudioVolumeDecibelRange(minimum: value.mMinimum, maximum: value.mMaximum)
    }

    func decibels(_ object: AudioObjectID) throws -> Float? {
        try volumeFloatProperty(object, selector: kAudioDevicePropertyVolumeDecibels)
    }

    func scalarToDecibels(_ object: AudioObjectID, value: Float) throws -> Float? {
        try volumeFloatProperty(object, selector: kAudioDevicePropertyVolumeScalarToDecibels, input: value)
    }

    func decibelsToScalar(_ object: AudioObjectID, value: Float) throws -> Float? {
        try volumeFloatProperty(object, selector: kAudioDevicePropertyVolumeDecibelsToScalar, input: value)
    }

    func mute(_ object: AudioObjectID, element: UInt32) throws -> AudioVolumeMuteEvidence? {
        var address = property(kAudioDevicePropertyMute, element: element)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        let value = try uint32(object, selector: kAudioDevicePropertyMute, element: element)
        guard value <= 1 else { throw AudioVolumeIssue.invalidReadback }
        return AudioVolumeMuteEvidence(value: value, writable: try writable(object, address: &address))
    }

    func outputElements(_ object: AudioObjectID) throws -> [UInt32] {
        var address = property(kAudioDevicePropertyStreamConfiguration)
        let bytes = try data(object: object, address: &address)
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard bytes.count >= offset else { throw AudioVolumeIssue.invalidReadback }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress { pointer.copyMemory(from: base, byteCount: bytes.count) }
        }
        let buffers = pointer.assumingMemoryBound(to: AudioBufferList.self)
        guard offset + Int(buffers.pointee.mNumberBuffers) * MemoryLayout<AudioBuffer>.stride <= bytes.count else { throw AudioVolumeIssue.invalidReadback }
        let count = UnsafeMutableAudioBufferListPointer(buffers).reduce(UInt64(0)) { $0 + UInt64($1.mNumberChannels) }
        guard count <= 4096 else { throw AudioVolumeIssue.invalidReadback }
        return count == 0 ? [] : Array(1...UInt32(count))
    }

    func hasProperty(_ object: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    func setScalar(_ object: AudioObjectID, value: Float) -> OSStatus {
        var address = property(kAudioDevicePropertyVolumeScalar)
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
    }

    func setMute(_ object: AudioObjectID, element: UInt32, value: UInt32) -> OSStatus {
        var address = property(kAudioDevicePropertyMute, element: element)
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    func addListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                     changed: @escaping @Sendable () -> Void) throws -> CoreAudioVolumeObservationState.Registration {
        let queue = DispatchQueue.global(qos: .utility)
        let delivery = AudioVolumeListenerDelivery(changed)
        let token = THVolumeListenerToken(object: object, address: address, queue: queue) { _, _ in delivery.signal() }
        let status = token.registerListener()
        guard status == noErr else { delivery.close(); throw AudioVolumeIssue.listenerUnavailable }
        return .init(object: object, address: address, queue: queue, token: token, delivery: delivery)
    }

    func removeListener(_ registration: CoreAudioVolumeObservationState.Registration) -> OSStatus {
        registration.token.removeListener()
    }

    private func property(_ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
                          element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func writable(_ object: AudioObjectID, address: inout AudioObjectPropertyAddress) throws -> Bool {
        var result = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(object, &address, &result)
        guard status == noErr else { throw AudioVolumeIssue.readFailed(status) }
        return result.boolValue
    }

    private func volumeFloatProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                                     input: Float = 0) throws -> Float? {
        var address = property(selector)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        // The conversion properties use the same Float32 as both input and output.
        var value = input
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioVolumeIssue.readFailed(status) }
        guard size == MemoryLayout<Float>.size else { throw AudioVolumeIssue.invalidReadback }
        return value
    }

    private func uint32(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
                        element: UInt32 = kAudioObjectPropertyElementMain) throws -> UInt32 {
        var address = property(selector, scope: scope, element: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioVolumeIssue.readFailed(status) }
        guard size == MemoryLayout<UInt32>.size else { throw AudioVolumeIssue.invalidReadback }
        return value
    }

    private func data(object: AudioObjectID, address: inout AudioObjectPropertyAddress) throws -> Data {
        for attempt in 0..<3 {
            var size: UInt32 = 0
            let sizing = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
            guard sizing == noErr else { throw AudioVolumeIssue.readFailed(sizing) }
            if size == 0 { return Data() }
            let capacity = size
            var data = Data(count: Int(size))
            let status = data.withUnsafeMutableBytes { bytes in AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!) }
            if status == noErr {
                guard size <= capacity else { throw AudioVolumeIssue.invalidReadback }
                return data.prefix(Int(size))
            }
            if attempt == 2 || status != kAudioHardwareBadPropertySizeError { throw AudioVolumeIssue.readFailed(status) }
        }
        throw AudioVolumeIssue.invalidReadback
    }
}
