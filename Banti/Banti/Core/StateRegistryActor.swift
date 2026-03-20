import Foundation
import os

actor StateRegistryActor {
    private let logger = Logger(subsystem: "com.banti.core", category: "StateRegistry")
    private var statuses: [ModuleID: ModuleHealth] = [:]
    private var errors: [ModuleID: any Error] = [:]

    func update(_ moduleID: ModuleID, status: ModuleHealth) {
        statuses[moduleID] = status
        if case .failed(let error) = status {
            errors[moduleID] = error
        }
    }

    func status(for moduleID: ModuleID) -> ModuleHealth? {
        statuses[moduleID]
    }

    func allStatuses() -> [ModuleID: ModuleHealth] {
        statuses
    }

    func lastError(for moduleID: ModuleID) -> (any Error)? {
        errors[moduleID]
    }
}
