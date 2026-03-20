import Foundation

struct AudioFrameEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let audioData: Data
    let sequenceNumber: UInt64
    let sampleRate: Int

    init(audioData: Data, sequenceNumber: UInt64, sampleRate: Int = 16000) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("mic-capture")
        self.audioData = audioData
        self.sequenceNumber = sequenceNumber
        self.sampleRate = sampleRate
    }
}
