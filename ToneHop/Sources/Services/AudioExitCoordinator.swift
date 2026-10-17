import Foundation

struct OwnedRouteExitEvidence: Sendable, Equatable {
    let receiverID: String
    let streamUID: String
    let name: String

    func matches(_ other: Self) -> Bool {
        receiverID == other.receiverID && streamUID == other.streamUID
    }
}

struct AudioExitPlan: Sendable, Equatable {
    let ownedStream: OwnedRouteExitEvidence?
    var serviceGeneration: UUID? = nil
    var requiresConfirmation: Bool { ownedStream != nil }
}

/// D policy: inspect without writes; after consent, select verified built-in
/// speakers, confirm HAL, and reuse the ordinary exact-owned-stream Remove.
/// Admission of UI requests and application termination remain with the caller.
@MainActor
struct AudioExitCoordinator {
    let hardware: any AudioHardwareProviding
    let routes: any PrivateRouting
    var readbackTimeout: Duration = .seconds(5)

    func prepare() async throws -> AudioExitPlan {
        let lease = try AudioServiceOperation.capture(from: hardware.serviceEpoch)
        return try await AudioServiceOperation.$lease.withValue(lease) {
            let owned = try await routes.ownedStreamForExit()
            try lease?.check()
            return AudioExitPlan(ownedStream: owned, serviceGeneration: lease?.id)
        }
    }

    func complete(_ plan: AudioExitPlan) async throws {
        let lease = try AudioServiceOperation.capture(from: hardware.serviceEpoch)
        guard plan.serviceGeneration == lease?.id else { throw AudioServiceResetError.serviceChanged }
        try await AudioServiceOperation.$lease.withValue(lease) {
            try await completeApprovedPlan(plan, lease: lease)
        }
    }

    private func completeApprovedPlan(_ plan: AudioExitPlan, lease: AudioServiceEpoch.Lease?) async throws {
        let current = try await routes.ownedStreamForExit()
        try lease?.check()
        // A flow already removed by normal reconciliation needs no further write.
        guard let current else { return }
        guard let approved = plan.ownedStream, approved.matches(current) else {
            throw AudioServiceError.unavailable(String(localized: "audio.exit_stream_changed", defaultValue: "The previous audio stream changed. Output and cleanup were left unchanged. Quit again to confirm."))
        }
        let speaker = try await hardware.builtInSpeaker()
        try lease?.check()
        guard speaker.isAvailable, case let .coreAudio(uid) = speaker.backend else {
            throw AudioServiceError.unavailable(String(localized: "audio.exit_speakers_unconfirmed", defaultValue: "The built-in Mac speakers could not be confirmed. The previous audio stream was not cleaned up."))
        }
        // Revalidate ownership after asynchronous HAL discovery, before any write.
        guard let beforeWrite = try await routes.ownedStreamForExit() else { return }
        guard approved.matches(beforeWrite) else {
            throw AudioServiceError.unavailable(String(localized: "audio.exit_stream_changed", defaultValue: "The previous audio stream changed. Output and cleanup were left unchanged. Quit again to confirm."))
        }
        try lease?.check()
        try await hardware.select(uid: uid)
        let deadline = ContinuousClock.now.advanced(by: readbackTimeout)
        while true {
            try Task.checkCancellation()
            try lease?.check()
            do {
                let snapshot = try await hardware.snapshot()
                if snapshot.currentDeviceID == speaker.id {
                    let verifiedSpeaker = try await hardware.builtInSpeaker()
                    guard verifiedSpeaker.id == speaker.id else {
                        throw AudioServiceError.unavailable(String(localized: "audio.exit_speakers_changed", defaultValue: "The built-in Mac speakers changed state. The previous audio stream was not cleaned up."))
                    }
                    break
                }
            } catch {
                // AirPlay may disappear between enumeration and a property
                // read after the HAL write. Retry only known stale-object reads;
                // never repeat the output write or infer success from an error.
                guard AudioHardwareReadFailure.isTransient(error) else { throw error }
            }
            guard ContinuousClock.now < deadline else {
                throw AudioServiceError.unavailable(String(localized: "audio.exit_output_unconfirmed", defaultValue: "The switch to the built-in Mac speakers could not be confirmed. Quit cleanup was not performed."))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // This path already validates current local output, stream ownership,
        // callback identity and empty readback; it never removes a borrowed flow.
        try lease?.check()
        try await routes.completedLeave()
        try lease?.check()
        guard try await routes.ownedStreamForExit() == nil else {
            throw AudioServiceError.unavailable(String(localized: "audio.exit_cleanup_unconfirmed", defaultValue: "Cleanup of the previous audio stream is not yet confirmed. The app will stay open. Try quitting again later."))
        }
    }
}
