import Foundation

enum AudioSelectionOrigin: Equatable, Sendable {
    case pointer
    case shortcut(bindingID: UUID)
}

struct AudioSelectionRequest: Equatable, Sendable {
    let id: UUID
    let origin: AudioSelectionOrigin

    init(id: UUID = UUID(), origin: AudioSelectionOrigin) {
        self.id = id
        self.origin = origin
    }
}

enum AudioSelectionOutcome: Equatable, Sendable {
    case selected
    case alreadySelected
    case failed(String)
    case ignored
}

struct AudioSelectionResult: Equatable, Sendable {
    let request: AudioSelectionRequest
    let outcome: AudioSelectionOutcome
}

enum AudioInteractionPhase: Hashable {
    case switching, quitting
}
