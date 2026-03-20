import XCTest
@testable import Banti

final class ModuleSupervisorActorTests: XCTestCase {
    override func setUp() async throws {
        MockPerceptionModule.resetCounter()
    }

    func testStartAllStartsRegisteredModules() async throws {
        let hub = EventHubActor()
        let registry = StateRegistryActor()
        let supervisor = ModuleSupervisorActor(eventHub: hub, stateRegistry: registry)
        let modA = MockPerceptionModule(id: "a")
        let modB = MockPerceptionModule(id: "b")

        await supervisor.register(modA, restartPolicy: .never)
        await supervisor.register(modB, restartPolicy: .never)
        try await supervisor.startAll()

        let aStarted = await modA.started
        let bStarted = await modB.started
        XCTAssertTrue(aStarted)
        XCTAssertTrue(bStarted)
    }

    func testStopAllStopsModules() async throws {
        let hub = EventHubActor()
        let registry = StateRegistryActor()
        let supervisor = ModuleSupervisorActor(eventHub: hub, stateRegistry: registry)
        let mod = MockPerceptionModule(id: "a")

        await supervisor.register(mod, restartPolicy: .never)
        try await supervisor.startAll()
        await supervisor.stopAll()

        let stopped = await mod.stopped
        XCTAssertTrue(stopped)
    }

    func testStartAllRollsBackOnFailure() async throws {
        let hub = EventHubActor()
        let registry = StateRegistryActor()
        let supervisor = ModuleSupervisorActor(eventHub: hub, stateRegistry: registry)
        let goodMod = MockPerceptionModule(id: "good")
        let badMod = MockPerceptionModule(id: "bad", shouldFail: true)

        await supervisor.register(goodMod, restartPolicy: .never)
        await supervisor.register(badMod, restartPolicy: .never,
                                  dependencies: [ModuleID("good")])

        do {
            try await supervisor.startAll()
            XCTFail("Should have thrown")
        } catch {}

        let goodStopped = await goodMod.stopped
        XCTAssertTrue(goodStopped, "Previously started module should be rolled back")
    }

    func testRestartModule() async throws {
        let hub = EventHubActor()
        let registry = StateRegistryActor()
        let supervisor = ModuleSupervisorActor(eventHub: hub, stateRegistry: registry)
        let mod = MockPerceptionModule(id: "a")

        await supervisor.register(mod, restartPolicy: .never)
        try await supervisor.startAll()
        try await supervisor.restart(ModuleID("a"))

        let started = await mod.started
        XCTAssertTrue(started)
    }
}
