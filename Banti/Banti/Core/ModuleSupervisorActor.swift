import Foundation
import os

actor ModuleSupervisorActor {
    private let logger = Logger(subsystem: "com.banti.core", category: "Supervisor")
    private let eventHub: EventHubActor
    private let stateRegistry: StateRegistryActor

    private struct ModuleEntry: Sendable {
        let module: any BantiModule
        let restartPolicy: RestartPolicy
        let dependencies: Set<ModuleID>
    }

    private var modules: [ModuleID: ModuleEntry] = [:]
    private var startOrder: [ModuleID] = []
    private var healthTask: Task<Void, Never>?

    init(eventHub: EventHubActor, stateRegistry: StateRegistryActor) {
        self.eventHub = eventHub
        self.stateRegistry = stateRegistry
    }

    func register(
        _ module: any BantiModule,
        restartPolicy: RestartPolicy,
        dependencies: Set<ModuleID> = []
    ) {
        let entry = ModuleEntry(
            module: module,
            restartPolicy: restartPolicy,
            dependencies: dependencies
        )
        modules[module.id] = entry
    }

    func startAll() async throws {
        let sorted = topologicalSort()
        for moduleID in sorted {
            guard let entry = modules[moduleID] else { continue }
            do {
                try await entry.module.start()
                await stateRegistry.update(moduleID, status: .healthy)
                startOrder.append(moduleID)
                logger.info("Started module: \(moduleID.rawValue)")
            } catch {
                await stateRegistry.update(moduleID, status: .failed(error: error))
                logger.error("Failed to start \(moduleID.rawValue): \(error.localizedDescription)")
                for started in startOrder.reversed() {
                    if let m = modules[started] {
                        await m.module.stop()
                    }
                }
                startOrder.removeAll()
                throw error
            }
        }
        startHealthPolling()
    }

    func stopAll() async {
        healthTask?.cancel()
        healthTask = nil
        for moduleID in startOrder.reversed() {
            if let entry = modules[moduleID] {
                await entry.module.stop()
                logger.info("Stopped module: \(moduleID.rawValue)")
            }
        }
        startOrder.removeAll()
    }

    func restart(_ moduleID: ModuleID) async throws {
        guard let entry = modules[moduleID] else { return }
        await entry.module.stop()
        try await entry.module.start()
        await stateRegistry.update(moduleID, status: .healthy)
    }

    private func startHealthPolling() {
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.pollHealth()
            }
        }
    }

    private func pollHealth() async {
        for (moduleID, entry) in modules {
            let health = await entry.module.health()
            let oldHealth = await stateRegistry.status(for: moduleID)
            let oldStr = oldHealth?.label ?? "unknown"
            let newStr = health.label
            if oldStr != newStr {
                await stateRegistry.update(moduleID, status: health)
                await eventHub.publish(ModuleStatusEvent(
                    moduleID: moduleID,
                    oldStatus: oldStr,
                    newStatus: newStr
                ))
            }
        }
    }

    private func topologicalSort() -> [ModuleID] {
        var visited = Set<ModuleID>()
        var result: [ModuleID] = []
        func visit(_ id: ModuleID) {
            guard !visited.contains(id) else { return }
            visited.insert(id)
            if let entry = modules[id] {
                for dep in entry.dependencies { visit(dep) }
            }
            result.append(id)
        }
        for id in modules.keys { visit(id) }
        return result
    }
}
