import Foundation

/// Value-only inspection of a short-lived HAL object. Never used as a stored
/// catalog identity; every mutation resolves the full UID again.
struct AudioVolumeInspection: Equatable, Sendable {
    let objectID: UInt32
    let snapshot: AudioVolumeSnapshot
    /// Internal evidence only. A scalar/dB pair must be read consistently before
    /// it may confirm a driver's equivalent representation of the request.
    let decibels: Float?

    init(objectID: UInt32, snapshot: AudioVolumeSnapshot, decibels: Float? = nil) {
        self.objectID = objectID
        self.snapshot = snapshot
        self.decibels = decibels
    }
}

struct AudioVolumeDecibelRange: Equatable, Sendable {
    let minimum: Double
    let maximum: Double

    var isValid: Bool { minimum.isFinite && maximum.isFinite && minimum <= maximum }
    func contains(_ value: Float) -> Bool {
        isValid && value.isFinite && minimum <= Double(value) && Double(value) <= maximum
    }
}

/// A driver's conversion is a candidate equivalent representation, not proof
/// that hardware reached it. Confirmation additionally requires actual scalar
/// and dB readback; a nearby value or a stable read is never enough.
struct AudioVolumeEquivalentTarget: Equatable, Sendable {
    let scalar: Float
    let decibels: Float
    let range: AudioVolumeDecibelRange
}

struct AudioVolumeWriteExpectation: Equatable, Sendable {
    let requestedScalar: Float
    let equivalent: AudioVolumeEquivalentTarget?

    init(requestedScalar: Float, equivalent: AudioVolumeEquivalentTarget? = nil) {
        self.requestedScalar = requestedScalar
        self.equivalent = equivalent
    }

    func confirms(_ inspection: AudioVolumeInspection) -> Bool {
        guard let actual = inspection.snapshot.value else { return false }
        if AudioVolumeTransaction.matches(actual, requested: requestedScalar) { return true }
        guard requestedScalar > 0, let equivalent,
              AudioVolumeScalar.validScalar(equivalent.scalar), equivalent.range.contains(equivalent.decibels),
              let actualDecibels = inspection.decibels else { return false }
        return AudioVolumeTransaction.matches(actual, requested: equivalent.scalar) &&
            AudioVolumeTransaction.matchesDecibels(actualDecibels, expected: equivalent.decibels)
    }
}

/// A muted device may ignore a volume write until it is unmuted. That case
/// permits one explicit recovery attempt, but does not certify a hidden gain.
enum AudioVolumeUnmuteExpectation: Equatable, Sendable {
    case confirmedVolume(AudioVolumeWriteExpectation)
    case unconfirmedMutedVolume(write: AudioVolumeWriteExpectation, observedValue: Float)

    var write: AudioVolumeWriteExpectation {
        switch self {
        case let .confirmedVolume(write), let .unconfirmedMutedVolume(write, _): write
        }
    }

    var requestedValue: Float { write.requestedScalar }
}

/// The transaction's normal production entry is also injectable in tests. Real
/// conformance is on CoreAudioService itself, on its existing actor and gate.
protocol AudioVolumeTransactionAccess: Actor {
    func inspectVolume(for target: AudioVolumeTarget, expectation: AudioVolumeWriteExpectation?) throws -> AudioVolumeInspection
    func prepareWriteExpectation(_ value: Float, for target: AudioVolumeTarget, expectedObject: UInt32) throws -> AudioVolumeWriteExpectation
    func submitVolume(_ expectation: AudioVolumeWriteExpectation, for target: AudioVolumeTarget,
                      expectedObject: UInt32, permit: AudioMutationPermit) throws
    func submitVolumeAfterUnmute(_ expectation: AudioVolumeWriteExpectation, for target: AudioVolumeTarget, expected: AudioVolumeInspection,
                                permit: AudioMutationPermit) throws
    func submitUnmute(for target: AudioVolumeTarget, expectedObject: UInt32, expectation: AudioVolumeUnmuteExpectation,
                      permit: AudioMutationPermit) throws
}

extension AudioVolumeTransactionAccess {
    /// Providers without conversion evidence retain the exact-scalar contract.
    func prepareWriteExpectation(_ value: Float, for target: AudioVolumeTarget,
                                 expectedObject: UInt32) throws -> AudioVolumeWriteExpectation {
        AudioVolumeWriteExpectation(requestedScalar: value)
    }
}

enum AudioVolumeTransaction {
    static func run(value: Float, target: AudioVolumeTarget, permit: AudioMutationPermit, access: any AudioVolumeTransactionAccess,
                    timeout: Duration = .seconds(2), interval: Duration = .milliseconds(40)) async throws -> AudioVolumeWriteResult {
        guard AudioVolumeScalar.validScalar(value) else { throw AudioVolumeIssue.invalidValue }
        try Task.checkCancellation()
        let initial = try await access.inspectVolume(for: target, expectation: nil)
        try validate(initial, target: target, objectID: initial.objectID)
        guard initial.snapshot.capability.canWrite else { throw initial.snapshot.capability.issue ?? .readOnly }
        try Task.checkCancellation()
        let write = try await access.prepareWriteExpectation(value, for: target, expectedObject: initial.objectID)
        guard write.requestedScalar == value else { throw AudioVolumeIssue.invalidReadback }
        try Task.checkCancellation()
        try await access.submitVolume(write, for: target, expectedObject: initial.objectID, permit: permit)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var actual = initial
        var confirmed = false
        repeat {
            try Task.checkCancellation()
            actual = try await access.inspectVolume(for: target, expectation: write)
            try validate(actual, target: target, objectID: initial.objectID)
            confirmed = write.confirms(actual)
            if confirmed { break }
            if .now >= deadline { break }
            try await Task.sleep(for: interval)
        } while true

        guard value > 0 else {
            // A muted scalar of zero may only describe audible output. It
            // cannot certify that the device's hidden restore value was reset.
            if actual.snapshot.mute.isAudiblyMuted {
                return AudioVolumeWriteResult(snapshot: actual.snapshot, issue: .mutedVolumeUnconfirmed)
            }
            if actual.snapshot.mute == .unknown {
                return AudioVolumeWriteResult(snapshot: actual.snapshot, issue: .unconfirmed)
            }
            return AudioVolumeWriteResult(snapshot: actual.snapshot, issue: confirmed ? nil : .unconfirmed)
        }
        let expectation: AudioVolumeUnmuteExpectation
        if confirmed {
            expectation = .confirmedVolume(write)
        } else {
            guard actual.snapshot.mute.isAudiblyMuted, actual.snapshot.canUnmute,
                  let observed = actual.snapshot.value else {
                return unconfirmedResult(actual.snapshot)
            }
            expectation = .unconfirmedMutedVolume(write: write, observedValue: observed)
        }
        try Task.checkCancellation()
        // A new observation must still agree with the precondition. In
        // particular, never turn a confirmed-then-changed value into recovery.
        actual = try await access.inspectVolume(for: target, expectation: write)
        try validate(actual, target: target, objectID: initial.objectID)
        switch expectation {
        case let .confirmedVolume(expected):
            guard expected.confirms(actual) else {
                return AudioVolumeWriteResult(snapshot: actual.snapshot, issue: .unconfirmed)
            }
        case let .unconfirmedMutedVolume(_, observed):
            guard actual.snapshot.mute.isAudiblyMuted, actual.snapshot.canUnmute,
                  actual.snapshot.value.map({ matches($0, requested: observed) }) == true else {
                return unconfirmedResult(actual.snapshot)
            }
        }
        guard actual.snapshot.mute.isAudiblyMuted else {
            return AudioVolumeWriteResult(snapshot: actual.snapshot,
                issue: actual.snapshot.mute == .unknown ? .muteUnknown : nil)
        }
        guard actual.snapshot.canUnmute else { return AudioVolumeWriteResult(snapshot: actual.snapshot, issue: .stillMuted) }
        try Task.checkCancellation()
        do { try await access.submitUnmute(for: target, expectedObject: initial.objectID, expectation: expectation, permit: permit) }
        catch is CancellationError { throw CancellationError() }
        catch let issue as AudioVolumeIssue where issue == .unconfirmed || issue == .identityChanged {
            throw issue
        }
        catch {
            // A failed setter may still have taken effect. Preserve the real
            // readback and report unconfirmed failure; never compensate blindly.
            let latest = try await access.inspectVolume(for: target, expectation: write)
            try validate(latest, target: target, objectID: initial.objectID)
            if latest.snapshot.mute.isAudiblyMuted,
               write.confirms(latest) {
                return AudioVolumeWriteResult(snapshot: latest.snapshot, issue: .stillMuted)
            }
            // Even an error followed by an unmuted readback does not authorize
            // the second volume write. Preserve the observed partial result.
            return unconfirmedResult(latest.snapshot, afterUnmute: true)
        }
        let muteDeadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            try Task.checkCancellation()
            actual = try await access.inspectVolume(for: target, expectation: write)
            try validate(actual, target: target, objectID: initial.objectID)
            if case .confirmedVolume = expectation,
               !write.confirms(actual) {
                return AudioVolumeWriteResult(snapshot: actual.snapshot, issue: .unconfirmed)
            }
            if actual.snapshot.mute == .unmuted { break }
            if actual.snapshot.mute == .unknown || actual.snapshot.mute == .unsupported {
                return AudioVolumeWriteResult(snapshot: actual.snapshot, issue: confirmed ? .muteUnknown : .unconfirmed)
            }
            if .now >= muteDeadline {
                return AudioVolumeWriteResult(snapshot: actual.snapshot, issue: confirmed ? .stillMuted : .mutedVolumeUnconfirmed)
            }
            try await Task.sleep(for: interval)
        } while true

        if case .confirmedVolume = expectation { return AudioVolumeWriteResult(snapshot: actual.snapshot) }
        if write.confirms(actual) {
            return AudioVolumeWriteResult(snapshot: actual.snapshot)
        }
        // Exactly one recovery write, only after a successful mute setter AND
        // an actual unmuted observation. The same revocable permit still gates
        // admission; cancellation cannot be bypassed to "finish" this sequence.
        try Task.checkCancellation()
        try await access.submitVolumeAfterUnmute(write, for: target, expected: actual, permit: permit)
        let recoveryDeadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            try Task.checkCancellation()
            actual = try await access.inspectVolume(for: target, expectation: write)
            try validate(actual, target: target, objectID: initial.objectID)
            let matched = write.confirms(actual)
            if matched && actual.snapshot.mute == .unmuted {
                return AudioVolumeWriteResult(snapshot: actual.snapshot)
            }
            if actual.snapshot.mute != .unmuted {
                return AudioVolumeWriteResult(snapshot: actual.snapshot,
                    issue: matched && actual.snapshot.mute.isAudiblyMuted ? .stillMuted : unconfirmedIssue(actual.snapshot, afterUnmute: true))
            }
            if .now >= recoveryDeadline { return unconfirmedResult(actual.snapshot, afterUnmute: true) }
            try await Task.sleep(for: interval)
        } while true
    }

    static func matches(_ actual: Float, requested: Float) -> Bool {
        guard AudioVolumeScalar.validScalar(actual), AudioVolumeScalar.validScalar(requested) else { return false }
        if actual == 0 || requested == 0 { return actual == requested }
        return abs(actual - requested) <= max(actual.ulp, requested.ulp) * 4
    }

    static func matchesDecibels(_ actual: Float, expected: Float) -> Bool {
        guard actual.isFinite, expected.isFinite else { return false }
        if actual == 0 || expected == 0 { return actual == expected }
        return abs(actual - expected) <= max(actual.ulp, expected.ulp) * 4
    }

    private static func unconfirmedIssue(_ snapshot: AudioVolumeSnapshot, afterUnmute: Bool = false) -> AudioVolumeIssue {
        if snapshot.mute.isAudiblyMuted { return .mutedVolumeUnconfirmed }
        return afterUnmute && snapshot.mute == .unmuted ? .unmutedVolumeUnconfirmed : .unconfirmed
    }

    private static func unconfirmedResult(_ snapshot: AudioVolumeSnapshot, afterUnmute: Bool = false) -> AudioVolumeWriteResult {
        AudioVolumeWriteResult(snapshot: snapshot, issue: unconfirmedIssue(snapshot, afterUnmute: afterUnmute))
    }

    private static func validate(_ inspection: AudioVolumeInspection, target: AudioVolumeTarget, objectID: UInt32) throws {
        guard inspection.objectID != 0, inspection.objectID == objectID, inspection.snapshot.target == target else {
            throw AudioVolumeIssue.identityChanged
        }
        if let value = inspection.snapshot.value, !AudioVolumeScalar.validScalar(value) {
            throw AudioVolumeIssue.invalidReadback
        }
        if inspection.snapshot.capability.canWrite && inspection.snapshot.value == nil {
            throw AudioVolumeIssue.invalidReadback
        }
    }
}
