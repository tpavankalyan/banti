import Foundation

struct ScreenChangeEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let jpeg: Data
    /// nil = first frame (no prior reference). Raw perceptual distance for subsequent frames.
    /// Value is >= SCREEN_CHANGE_THRESHOLD as a consequence of gating, not a type guarantee.
    let changeDistance: Float?
    let sequenceNumber: UInt64
    let captureTime: Date

    init(jpeg: Data, changeDistance: Float?, sequenceNumber: UInt64, captureTime: Date) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("screen-change-detection")
        self.jpeg = jpeg
        self.changeDistance = changeDistance
        self.sequenceNumber = sequenceNumber
        self.captureTime = captureTime
    }
}
