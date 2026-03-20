import Foundation

struct ModuleStatusEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let moduleID: ModuleID
    let oldStatus: String
    let newStatus: String

    init(moduleID: ModuleID, oldStatus: String, newStatus: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("supervisor")
        self.moduleID = moduleID
        self.oldStatus = oldStatus
        self.newStatus = newStatus
    }
}
