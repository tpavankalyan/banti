import Foundation

struct SceneDescriptionEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let text: String
    let captureTime: Date
    let responseTime: Date

    init(text: String, captureTime: Date, responseTime: Date) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("scene-description")
        self.text = text
        self.captureTime = captureTime
        self.responseTime = responseTime
    }
}
