import Foundation

struct SpeechPlaybackEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let isPlaying: Bool

    init(isPlaying: Bool) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("speech")
        self.isPlaying = isPlaying
    }
}
