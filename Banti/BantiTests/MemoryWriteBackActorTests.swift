import XCTest
@testable import Banti

// MARK: - Test doubles

/// Records every ingestTurn call for assertion.
actor StubMemoryClient: MemoryClient {
    private(set) var calls: [(userText: String, responseText: String)] = []

    func ingestTurn(userText: String, responseText: String) async throws {
        calls.append((userText: userText, responseText: responseText))
    }
}

/// Always throws so we can test graceful error handling.
actor ThrowingMemoryClient: MemoryClient {
    struct FakeSidecarError: Error {}
    func ingestTurn(userText: String, responseText: String) async throws {
        throw FakeSidecarError()
    }
}

// MARK: - Tests

final class MemoryWriteBackActorTests: XCTestCase {

    func waitUntil(_ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while await !condition() {
            guard Date() < deadline else { return }
            await Task.yield()
        }
    }

    // MARK: - Ingest called on event

    func testIngestCalledOnAgentResponse() async throws {
        let hub = EventHubActor()
        let stub = StubMemoryClient()
        let actor = MemoryWriteBackActor(eventHub: hub, memoryClient: stub)
        try await actor.start()

        await hub.publish(AgentResponseEvent(userText: "hello", responseText: "hi"))
        await waitUntil { await stub.calls.count == 1 }

        let count = await stub.calls.count
        XCTAssertEqual(count, 1)
    }

    func testIngestReceivesCorrectUserText() async throws {
        let hub = EventHubActor()
        let stub = StubMemoryClient()
        let actor = MemoryWriteBackActor(eventHub: hub, memoryClient: stub)
        try await actor.start()

        await hub.publish(AgentResponseEvent(userText: "what time is it?", responseText: "I don't know"))
        await waitUntil { await stub.calls.count == 1 }

        let first = await stub.calls.first
        XCTAssertEqual(first?.userText, "what time is it?")
    }

    func testIngestReceivesCorrectResponseText() async throws {
        let hub = EventHubActor()
        let stub = StubMemoryClient()
        let actor = MemoryWriteBackActor(eventHub: hub, memoryClient: stub)
        try await actor.start()

        await hub.publish(AgentResponseEvent(userText: "q", responseText: "use a computed property"))
        await waitUntil { await stub.calls.count == 1 }

        let first = await stub.calls.first
        XCTAssertEqual(first?.responseText, "use a computed property")
    }

    func testIngestCalledOncePerEvent() async throws {
        let hub = EventHubActor()
        let stub = StubMemoryClient()
        let actor = MemoryWriteBackActor(eventHub: hub, memoryClient: stub)
        try await actor.start()

        await hub.publish(AgentResponseEvent(userText: "a", responseText: "1"))
        await hub.publish(AgentResponseEvent(userText: "b", responseText: "2"))
        await hub.publish(AgentResponseEvent(userText: "c", responseText: "3"))
        await waitUntil { await stub.calls.count == 3 }

        let count = await stub.calls.count
        XCTAssertEqual(count, 3)
    }

    // MARK: - Error handling (fire-and-forget)

    func testSidecarErrorDoesNotDegradeHealth() async throws {
        let hub = EventHubActor()
        let throwingClient = ThrowingMemoryClient()
        let actor = MemoryWriteBackActor(eventHub: hub, memoryClient: throwingClient)
        try await actor.start()

        await hub.publish(AgentResponseEvent(userText: "hello", responseText: "hi"))
        try await Task.sleep(for: .milliseconds(200))

        let health = await actor.health()
        if case .healthy = health {
            // expected — sidecar being down is not fatal
        } else {
            XCTFail("Expected .healthy after sidecar error, got \(health)")
        }
    }

    // MARK: - Stop unsubscribes

    func testNoIngestAfterStop() async throws {
        let hub = EventHubActor()
        let stub = StubMemoryClient()
        let actor = MemoryWriteBackActor(eventHub: hub, memoryClient: stub)
        try await actor.start()
        await actor.stop()

        await hub.publish(AgentResponseEvent(userText: "hello", responseText: "hi"))
        try await Task.sleep(for: .milliseconds(200))

        let count = await stub.calls.count
        XCTAssertEqual(count, 0)
    }
}
