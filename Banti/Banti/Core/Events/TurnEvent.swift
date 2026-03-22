import Foundation

/// Published when the first final transcript segment of a new turn arrives.
struct TurnStartedEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID

    init() {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("turn-detector")
    }
}

/// Published after a turn ends: a final transcript segment was received
/// and no new segments arrived within the silence window.
/// `text` is the space-joined content of all final segments in the turn.
struct TurnEndedEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let text: String

    init(text: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("turn-detector")
        self.text = text
    }
}
