import CoreAudio
import Foundation

/// One synchronous HAL selection on the caller's existing audio executor.
/// Reads are injected at this boundary so identity changes can be exercised
/// without installing process-wide hooks or issuing real system writes.
enum CoreAudioOutputSelection {
    static func submit(
        uid: String,
        deviceIDs: () throws -> [AudioObjectID],
        readUID: (AudioObjectID) throws -> String,
        readAvailability: (AudioObjectID) throws -> (canBeDefaultOutput: Bool, alive: Bool),
        checkSettable: () throws -> Void,
        checkRunning: () throws -> Void,
        performIfRunning: @escaping (_ operation: () -> Void) -> Bool,
        write: (AudioObjectID) throws -> Void
    ) throws {
        func resolve() throws -> AudioObjectID {
            let matches = try deviceIDs().filter { (try? readUID($0)) == uid }
            guard matches.count == 1, let object = matches.first else {
                throw matches.isEmpty ? AudioServiceError.targetMissing : AudioServiceError.ambiguousIdentity
            }
            let availability = try readAvailability(object)
            // Capability reads may outlive hot-plug or a driver restart. A new
            // occupant of the object ID cannot inherit the first UID match.
            guard availability.canBeDefaultOutput, availability.alive,
                  try readUID(object) == uid else { throw AudioServiceError.targetMissing }
            return object
        }

        try checkRunning()
        let expectedObject = try resolve()
        try checkSettable()
        try checkRunning()
        var result: Result<Void, any Error> = .failure(CancellationError())
        guard performIfRunning({
            result = Result {
                // Registration uses the existing shutdown/epoch boundary. Even
                // the same UID on a replacement object requires a fresh request.
                guard try resolve() == expectedObject else { throw AudioServiceError.targetMissing }
                try write(expectedObject)
            }
        }) else { throw CancellationError() }
        try result.get()
    }
}
