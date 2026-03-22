import XCTest
@testable import Banti

// MARK: - Test doubles

/// Records every call and returns a canned response.
actor StubAgentProvider: AgentLLMProvider {
    let cannedResponse: String
    private(set) var receivedSystemPrompt: String?
    private(set) var receivedUserText: String?
    private(set) var callCount: Int = 0

    init(response: String = "stub response") {
        self.cannedResponse = response
    }

    func respond(systemPrompt: String, userText: String) async throws -> String {
        receivedSystemPrompt = systemPrompt
        receivedUserText = userText
        callCount += 1
        return cannedResponse
    }
}

/// Always throws so we can test error-path behaviour.
actor ThrowingAgentProvider: AgentLLMProvider {
    struct FakeLLMError: Error {}
    func respond(systemPrompt: String, userText: String) async throws -> String {
        throw FakeLLMError()
    }
}

// MARK: - Tests

final class AgentBridgeActorTests: XCTestCase {

    // MARK: - Helpers

    func makeTurnEnded(text: String = "let's refactor this") -> TurnEndedEvent {
        TurnEndedEvent(text: text)
    }

    func makeActiveApp(name: String = "Xcode") -> ActiveAppEvent {
        ActiveAppEvent(bundleIdentifier: "com.apple.dt.Xcode", appName: name,
                       previousBundleIdentifier: nil, previousAppName: nil)
    }

    func waitUntil(_ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while await !condition() {
            guard Date() < deadline else { return }
            await Task.yield()
        }
    }

    // MARK: - AgentResponseEvent pub/sub

    func testAgentResponseEventCanBePubSubbed() async throws {
        let hub = EventHubActor()
        var received: AgentResponseEvent?
        let subID = await hub.subscribe(AgentResponseEvent.self) { received = $0 }

        await hub.publish(AgentResponseEvent(userText: "hello", responseText: "hi there"))

        await waitUntil { received != nil }
        XCTAssertEqual(received?.responseText, "hi there")
        await hub.unsubscribe(subID)
    }

    // MARK: - Bridge fires on TurnEndedEvent

    func testAgentResponsePublishedAfterTurnEnded() async throws {
        let hub = EventHubActor()
        let snapActor = ContextSnapshotActor(eventHub: hub)
        try await snapActor.start()
        let stub = StubAgentProvider()
        let bridge = AgentBridgeActor(eventHub: hub, contextSnapshot: snapActor, llmProvider: stub)
        try await bridge.start()

        var received: AgentResponseEvent?
        let subID = await hub.subscribe(AgentResponseEvent.self) { received = $0 }

        await hub.publish(makeTurnEnded())
        await waitUntil { received != nil }

        XCTAssertNotNil(received)
        await hub.unsubscribe(subID)
    }

    func testAgentResponseTextMatchesLLMOutput() async throws {
        let hub = EventHubActor()
        let snapActor = ContextSnapshotActor(eventHub: hub)
        try await snapActor.start()
        let stub = StubAgentProvider(response: "use a computed property instead")
        let bridge = AgentBridgeActor(eventHub: hub, contextSnapshot: snapActor, llmProvider: stub)
        try await bridge.start()

        var received: AgentResponseEvent?
        let subID = await hub.subscribe(AgentResponseEvent.self) { received = $0 }

        await hub.publish(makeTurnEnded(text: "how do I do X?"))
        await waitUntil { received != nil }

        XCTAssertEqual(received?.responseText, "use a computed property instead")
        await hub.unsubscribe(subID)
    }

    func testAgentResponseUserTextMatchesTurn() async throws {
        let hub = EventHubActor()
        let snapActor = ContextSnapshotActor(eventHub: hub)
        try await snapActor.start()
        let stub = StubAgentProvider()
        let bridge = AgentBridgeActor(eventHub: hub, contextSnapshot: snapActor, llmProvider: stub)
        try await bridge.start()

        var received: AgentResponseEvent?
        let subID = await hub.subscribe(AgentResponseEvent.self) { received = $0 }

        await hub.publish(makeTurnEnded(text: "explain closures"))
        await waitUntil { received != nil }

        XCTAssertEqual(received?.userText, "explain closures")
        await hub.unsubscribe(subID)
    }

    // MARK: - System prompt includes context snapshot

    func testContextSnapshotIncludedInSystemPrompt() async throws {
        let hub = EventHubActor()
        let snapActor = ContextSnapshotActor(eventHub: hub)
        try await snapActor.start()

        // Seed the snapshot with a recognisable app name
        await hub.publish(makeActiveApp(name: "Figma"))
        await waitUntil { await snapActor.snapshot().activeApp != nil }

        let stub = StubAgentProvider()
        let bridge = AgentBridgeActor(eventHub: hub, contextSnapshot: snapActor, llmProvider: stub)
        try await bridge.start()

        var received: AgentResponseEvent?
        let subID = await hub.subscribe(AgentResponseEvent.self) { received = $0 }

        await hub.publish(makeTurnEnded())
        await waitUntil { received != nil }

        let prompt = await stub.receivedSystemPrompt ?? ""
        XCTAssertTrue(prompt.contains("Figma"),
                      "Expected system prompt to contain snapshot data but got: \(prompt)")
        await hub.unsubscribe(subID)
    }

    // MARK: - Error handling

    func testLLMErrorDoesNotPublishResponse() async throws {
        let hub = EventHubActor()
        let snapActor = ContextSnapshotActor(eventHub: hub)
        try await snapActor.start()
        let bridge = AgentBridgeActor(eventHub: hub, contextSnapshot: snapActor,
                                      llmProvider: ThrowingAgentProvider())
        try await bridge.start()

        var received: AgentResponseEvent?
        let subID = await hub.subscribe(AgentResponseEvent.self) { received = $0 }

        await hub.publish(makeTurnEnded())
        // Wait longer than any async work; nothing should arrive
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(received)
        await hub.unsubscribe(subID)
    }

    func testLLMErrorSetsHealthDegraded() async throws {
        let hub = EventHubActor()
        let snapActor = ContextSnapshotActor(eventHub: hub)
        try await snapActor.start()
        let bridge = AgentBridgeActor(eventHub: hub, contextSnapshot: snapActor,
                                      llmProvider: ThrowingAgentProvider())
        try await bridge.start()

        await hub.publish(makeTurnEnded())

        await waitUntil {
            let h = await bridge.health()
            if case .degraded = h { return true }
            return false
        }

        let health = await bridge.health()
        if case .degraded = health {
            // Expected
        } else {
            XCTFail("Expected health .degraded after LLM error, got \(health)")
        }
    }
}
