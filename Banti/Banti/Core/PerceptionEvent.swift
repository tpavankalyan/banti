import Foundation

struct SubscriptionID: Hashable, Sendable {
    let rawValue: UUID
    init() { self.rawValue = UUID() }
}

protocol PerceptionEvent: Sendable {
    var id: UUID { get }
    var timestamp: Date { get }
    var sourceModule: ModuleID { get }
}
