import Foundation

struct SceneDescriptionEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let text: String
    let captureTime: Date
    let responseTime: Date
    /// Distance from the prior frame that triggered this description. 0.0 = first frame.
    let changeDistance: Float

    init(text: String, captureTime: Date, responseTime: Date, changeDistance: Float) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("scene-description")
        self.text = text
        self.captureTime = captureTime
        self.responseTime = responseTime
        self.changeDistance = changeDistance
    }
}
