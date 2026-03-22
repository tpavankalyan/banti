import Foundation

/// Published by AgentBridgeActor after Claude responds to a turn.
struct AgentResponseEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    /// The user's spoken text that triggered this response (from TurnEndedEvent).
    let userText: String
    /// Claude's response text.
    let responseText: String

    init(userText: String, responseText: String,
         sourceModule: ModuleID = ModuleID("agent-bridge")) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = sourceModule
        self.userText = userText
        self.responseText = responseText
    }
}
