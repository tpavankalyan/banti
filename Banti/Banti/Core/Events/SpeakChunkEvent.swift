import Foundation

/// Published by CognitiveCoreActor for each sentence-complete text chunk to speak.
struct SpeakChunkEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let text: String
    /// Epoch from CognitiveCoreActor; StreamingTTSActor discards chunks whose epoch is stale.
    let epoch: Int

    init(text: String, epoch: Int) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("cognitive-core")
        self.text = text
        self.epoch = epoch
    }
}
