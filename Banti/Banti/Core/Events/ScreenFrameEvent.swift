import Foundation

struct ScreenFrameEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let jpeg: Data
    let sequenceNumber: UInt64
    let displayWidth: Int
    let displayHeight: Int

    init(jpeg: Data, sequenceNumber: UInt64, displayWidth: Int, displayHeight: Int) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("screen-capture")
        self.jpeg = jpeg
        self.sequenceNumber = sequenceNumber
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }
}
