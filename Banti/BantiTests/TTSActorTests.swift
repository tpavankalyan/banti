import XCTest
@testable import Banti

// MARK: - Test doubles

/// Records every synthesize call; returns empty Data (AVAudioPlayer init will fail, actor handles gracefully).
actor StubTTSProvider: TTSProvider {
    private(set) var calls: [String] = []

    func synthesize(text: String) async throws -> Data {
        calls.append(text)
        return Data()
    }
}

/// Always throws to test error-path behaviour.
actor ThrowingTTSProvider: TTSProvider {
    func synthesize(text: String) async throws -> Data {
        throw TTSError("network failed")
    }
}

// MARK: - Tests

final class TTSActorTests: XCTestCase {

    func waitUntil(_ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while await !condition() {
            guard Date() < deadline else { return }
            await Task.yield()
        }
    }

    // MARK: - Synthesize called on event

    func testSynthesizeCalledOnAgentResponse() async throws {
        let hub = EventHubActor()
        let stub = StubTTSProvider()
        let actor = TTSActor(eventHub: hub, ttsProvider: stub)
        try await actor.start()

        await hub.publish(AgentResponseEvent(userText: "hello", responseText: "hi there"))
        await waitUntil { await stub.calls.count == 1 }

        let count = await stub.calls.count
        XCTAssertEqual(count, 1)
    }

    func testSynthesizeReceivesResponseText() async throws {
        let hub = EventHubActor()
        let stub = StubTTSProvider()
        let actor = TTSActor(eventHub: hub, ttsProvider: stub)
        try await actor.start()

        await hub.publish(AgentResponseEvent(userText: "q", responseText: "use a computed property"))
        await waitUntil { await stub.calls.count == 1 }

        let first = await stub.calls.first
        XCTAssertEqual(first, "use a computed property")
    }

    func testSynthesizeCalledOncePerEvent() async throws {
        let hub = EventHubActor()
        let stub = StubTTSProvider()
        let actor = TTSActor(eventHub: hub, ttsProvider: stub)
        try await actor.start()

        await hub.publish(AgentResponseEvent(userText: "a", responseText: "one"))
        await hub.publish(AgentResponseEvent(userText: "b", responseText: "two"))
        await hub.publish(AgentResponseEvent(userText: "c", responseText: "three"))
        await waitUntil { await stub.calls.count == 3 }

        let count = await stub.calls.count
        XCTAssertEqual(count, 3)
    }

    // MARK: - Error handling

    func testTTSErrorDoesNotDegradeHealth() async throws {
        let hub = EventHubActor()
        let throwingProvider = ThrowingTTSProvider()
        let actor = TTSActor(eventHub: hub, ttsProvider: throwingProvider)
        try await actor.start()

        await hub.publish(AgentResponseEvent(userText: "hello", responseText: "hi"))
        try await Task.sleep(for: .milliseconds(200))

        let health = await actor.health()
        if case .healthy = health {
            // expected — TTS failures are non-fatal
        } else {
            XCTFail("Expected .healthy after TTS error, got \(health)")
        }
    }

    // MARK: - Stop unsubscribes

    func testNoSynthesizeAfterStop() async throws {
        let hub = EventHubActor()
        let stub = StubTTSProvider()
        let actor = TTSActor(eventHub: hub, ttsProvider: stub)
        try await actor.start()
        await actor.stop()

        await hub.publish(AgentResponseEvent(userText: "hello", responseText: "hi"))
        try await Task.sleep(for: .milliseconds(200))

        let count = await stub.calls.count
        XCTAssertEqual(count, 0)
    }
}
