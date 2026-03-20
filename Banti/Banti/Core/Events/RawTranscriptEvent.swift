import Foundation

struct RawTranscriptEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let text: String
    let speakerIndex: Int?
    let confidence: Double
    let isFinal: Bool
    let audioStartTime: TimeInterval
    let audioEndTime: TimeInterval

    init(text: String, speakerIndex: Int?, confidence: Double,
         isFinal: Bool, audioStartTime: TimeInterval, audioEndTime: TimeInterval) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("deepgram-asr")
        self.text = text
        self.speakerIndex = speakerIndex
        self.confidence = confidence
        self.isFinal = isFinal
        self.audioStartTime = audioStartTime
        self.audioEndTime = audioEndTime
    }
}
