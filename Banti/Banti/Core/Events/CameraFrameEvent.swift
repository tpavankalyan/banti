import Foundation

struct CameraFrameEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let jpeg: Data
    let sequenceNumber: UInt64
    let frameWidth: Int
    let frameHeight: Int

    init(jpeg: Data, sequenceNumber: UInt64, frameWidth: Int, frameHeight: Int) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("camera-capture")
        self.jpeg = jpeg
        self.sequenceNumber = sequenceNumber
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }
}
