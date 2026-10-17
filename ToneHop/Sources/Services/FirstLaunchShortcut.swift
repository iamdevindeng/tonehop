import Carbon.HIToolbox
import Foundation

/// Adapts the existing verified speaker lookup to a single starter binding.
/// It never selects an output or infers identity from the current route/name.
enum FirstLaunchShortcut {
    static func builtInSpeaker(using hardware: any AudioHardwareProviding) async throws -> ShortcutBinding {
        let speaker = try await hardware.builtInSpeaker()
        guard speaker.isAvailable, case let .coreAudio(uid) = speaker.backend,
              !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              speaker.id == "hal:\(uid)" else { throw AudioServiceError.ambiguousIdentity }
        return ShortcutBinding(target: .hal(uid: uid),
                               shortcut: try DeviceShortcut(keyCode: UInt16(kVK_ANSI_1),
                                                            modifiers: [.control, .shift]),
                               lastKnownName: speaker.name)
    }
}
