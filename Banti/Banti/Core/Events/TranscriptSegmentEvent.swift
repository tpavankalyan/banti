import Foundation

struct TranscriptSegmentEvent: PerceptionEvent, Identifiable {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let speakerLabel: String
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let isFinal: Bool

    init(speakerLabel: String, text: String,
         startTime: TimeInterval, endTime: TimeInterval, isFinal: Bool) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("transcript-projection")
        self.speakerLabel = speakerLabel
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.isFinal = isFinal
    }
}
