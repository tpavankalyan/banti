import Foundation

struct BrainResponseEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let text: String

    init(text: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("brain")
        self.text = text
    }
}
