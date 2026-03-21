import Foundation

struct BrainThoughtEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let text: String
    let action: String

    init(text: String, action: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("brain")
        self.text = text
        self.action = action
    }
}
