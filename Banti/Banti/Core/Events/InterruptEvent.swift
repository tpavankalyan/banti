import Foundation

/// Published by CognitiveCoreActor when barge-in occurs.
/// StreamingTTSActor sets (not increments) its epoch to this value.
struct InterruptEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let epoch: Int

    init(epoch: Int) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("cognitive-core")
        self.epoch = epoch
    }
}
