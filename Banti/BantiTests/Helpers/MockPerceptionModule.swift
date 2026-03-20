import Foundation
@testable import Banti

actor MockPerceptionModule: PerceptionModule {
    nonisolated let id: ModuleID
    nonisolated let capabilities: Set<Capability>
    var started = false
    var stopped = false
    var shouldFail = false
    var startOrder: Int = 0
    private var _health: ModuleHealth = .healthy

    nonisolated(unsafe) static var globalStartCounter = 0

    static func resetCounter() { globalStartCounter = 0 }

    init(id: String, shouldFail: Bool = false) {
        self.id = ModuleID(id)
        self.capabilities = [Capability("mock")]
        self.shouldFail = shouldFail
    }

    func start() async throws {
        if shouldFail { throw ConfigError(message: "mock failure") }
        MockPerceptionModule.globalStartCounter += 1
        startOrder = MockPerceptionModule.globalStartCounter
        started = true
    }

    func stop() async {
        stopped = true
        started = false
    }

    func health() async -> ModuleHealth { _health }

    func setHealth(_ h: ModuleHealth) { _health = h }
}
