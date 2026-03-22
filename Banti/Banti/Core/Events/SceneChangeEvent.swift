import Foundation

struct SceneChangeEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let jpeg: Data
    /// Perceptual distance from prior frame. 0.0 = first frame (no reference). Higher = more different.
    let changeDistance: Float
    let sequenceNumber: UInt64
    let captureTime: Date

    init(jpeg: Data, changeDistance: Float, sequenceNumber: UInt64, captureTime: Date) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("scene-change-detection")
        self.jpeg = jpeg
        self.changeDistance = changeDistance
        self.sequenceNumber = sequenceNumber
        self.captureTime = captureTime
    }
}
