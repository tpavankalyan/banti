import Foundation

struct ScreenDescriptionEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let text: String
    let captureTime: Date
    let responseTime: Date
    /// nil for first-frame descriptions (changeDistance was nil in the source ScreenChangeEvent).
    /// Raw measured perceptual distance otherwise.
    let changeDistance: Float?

    init(text: String, captureTime: Date, responseTime: Date, changeDistance: Float?) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("screen-description")
        self.text = text
        self.captureTime = captureTime
        self.responseTime = responseTime
        self.changeDistance = changeDistance
    }
}
