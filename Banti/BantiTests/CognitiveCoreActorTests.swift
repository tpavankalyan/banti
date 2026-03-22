// Banti/BantiTests/CognitiveCoreActorTests.swift
import XCTest
@testable import Banti

// MARK: - Stubs

/// Configurable stub — emits a fixed sequence of events and records calls.
final class StubStreamingLLMProvider: AgentLLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _responseEvents: [AgentStreamEvent] = [.silent]
    private var _callCount = 0
    private var _lastTriggerSource: String?

    var responseEvents: [AgentStreamEvent] {
        get { lock.withLock { _responseEvents } }
        set { lock.withLock { _responseEvents = newValue } }
    }
    var callCount: Int { lock.withLock { _callCount } }
    var lastTriggerSource: String? { lock.withLock { _lastTriggerSource } }

    func streamResponse(
        systemPrompt: CachedPromptBlock,
        olderContext: CachedPromptBlock,
        recentContext: String,
        triggerSource: String
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let events = lock.withLock {
            _callCount += 1
            _lastTriggerSource = triggerSource
            return _responseEvents
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Never finishes — used to test barge-in cancellation.
final class InfiniteStreamingStub: AgentLLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    func streamResponse(
        systemPrompt: CachedPromptBlock,
        olderContext: CachedPromptBlock,
        recentContext: String,
        triggerSource: String
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        lock.withLock { _callCount += 1 }
        return AsyncThrowingStream { _ in
            // Never yields or finishes — hangs until task is cancelled
        }
    }
}

// MARK: - Tests

final class CognitiveCoreActorTests: XCTestCase {

    func waitUntil(_ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while await !condition() {
            guard Date() < deadline else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func makeHub() -> EventHubActor { EventHubActor() }

    func makeLog(hub: EventHubActor) async throws -> PerceptionLogActor {
        let log = PerceptionLogActor(eventHub: hub)
        try await log.start()
        return log
    }

    func makeTurnEnded(text: String = "hello") -> TurnEndedEvent { TurnEndedEvent(text: text) }
    func makeTurnStarted() -> TurnStartedEvent { TurnStartedEvent() }

    func makeScreenDesc(dist: Float = 0.8) -> ScreenDescriptionEvent {
        ScreenDescriptionEvent(text: "screen changed", captureTime: Date(), responseTime: Date(), changeDistance: dist)
    }

    // MARK: - TurnEndedEvent always fires

    func testTurnEndedAlwaysTriggers() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        await hub.publish(makeTurnEnded())
        await waitUntil { stub.callCount == 1 }
        await hub.publish(makeTurnEnded())
        await waitUntil { stub.callCount == 2 }

        XCTAssertEqual(stub.callCount, 2)
    }

    // MARK: - Screen event debounce

    func testScreenEventDebounced() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        // 1s interval so two events fired 100ms apart result in only one call
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub,
                                      screenInterval: 1.0, screenThreshold: 0.3)
        try await core.start()

        await hub.publish(makeScreenDesc(dist: 0.8))
        await hub.publish(makeScreenDesc(dist: 0.8))
        await waitUntil { await stub.callCount >= 1 }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(stub.callCount, 1, "Second event within interval should be coalesced")
    }

    func testScreenEventBelowThresholdNotTriggered() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub,
                                      screenThreshold: 0.5)
        try await core.start()

        await hub.publish(makeScreenDesc(dist: 0.1)) // below threshold
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(stub.callCount, 0)
    }

    // MARK: - Silent path

    func testSilentPathPublishesNothingToTTS() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        stub.responseEvents = [.silent]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var chunks: [SpeakChunkEvent] = []
        let subID = await hub.subscribe(SpeakChunkEvent.self) { chunks.append($0) }

        await hub.publish(makeTurnEnded())
        await waitUntil { stub.callCount == 1 }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(chunks.isEmpty)
        await hub.unsubscribe(subID)
    }

    func testSilentPathPublishesNoAgentResponse() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        stub.responseEvents = [.silent]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var responses: [AgentResponseEvent] = []
        let subID = await hub.subscribe(AgentResponseEvent.self) { responses.append($0) }

        await hub.publish(makeTurnEnded())
        await waitUntil { stub.callCount == 1 }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(responses.isEmpty)
        await hub.unsubscribe(subID)
    }

    // MARK: - Speak path

    func testSpeakPathPublishesSpeakChunk() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        // 16+ chars to pass minimum length check, ends with period
        stub.responseEvents = [.speakChunk("This is a response."), .speakDone]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var chunks: [SpeakChunkEvent] = []
        let subID = await hub.subscribe(SpeakChunkEvent.self) { chunks.append($0) }

        await hub.publish(makeTurnEnded(text: "help me"))
        await waitUntil { !chunks.isEmpty }

        XCTAssertTrue(chunks[0].text.contains("This is a response"))
        await hub.unsubscribe(subID)
    }

    func testSpeakPathPublishesAgentResponseOnDone() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        stub.responseEvents = [.speakChunk("Use a computed property."), .speakDone]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var responses: [AgentResponseEvent] = []
        let subID = await hub.subscribe(AgentResponseEvent.self) { responses.append($0) }

        await hub.publish(makeTurnEnded(text: "how do I do X?"))
        await waitUntil { !responses.isEmpty }

        XCTAssertEqual(responses[0].userText, "how do I do X?")
        XCTAssertEqual(responses[0].responseText, "Use a computed property.")
        await hub.unsubscribe(subID)
    }

    func testProactiveSpeakHasEmptyUserText() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        stub.responseEvents = [.speakChunk("Your build just failed."), .speakDone]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub,
                                      screenInterval: 0, screenThreshold: 0)
        try await core.start()

        var responses: [AgentResponseEvent] = []
        let subID = await hub.subscribe(AgentResponseEvent.self) { responses.append($0) }

        await hub.publish(makeScreenDesc(dist: 0.9))
        await waitUntil { !responses.isEmpty }

        XCTAssertEqual(responses[0].userText, "")
        await hub.unsubscribe(subID)
    }

    // MARK: - Sentence boundary chunking

    func testShortChunkAccumulatesUntilSentenceBoundary() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        // Short fragments that together exceed 15 chars and end with period
        stub.responseEvents = [
            .speakChunk("Use a "),
            .speakChunk("computed "),
            .speakChunk("property."),
            .speakDone
        ]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var chunks: [SpeakChunkEvent] = []
        let subID = await hub.subscribe(SpeakChunkEvent.self) { chunks.append($0) }

        await hub.publish(makeTurnEnded())
        await waitUntil { !chunks.isEmpty }
        try await Task.sleep(for: .milliseconds(100))

        // Should be one flushed chunk (accumulated then flushed at period)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].text.contains("computed property"))
        await hub.unsubscribe(subID)
    }

    func testRemainingBufferFlushedOnDone() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        // No sentence-ending punctuation — should flush on speakDone
        stub.responseEvents = [.speakChunk("sure"), .speakDone]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var chunks: [SpeakChunkEvent] = []
        let subID = await hub.subscribe(SpeakChunkEvent.self) { chunks.append($0) }

        await hub.publish(makeTurnEnded())
        await waitUntil { !chunks.isEmpty }

        XCTAssertEqual(chunks[0].text, "sure")
        await hub.unsubscribe(subID)
    }

    // MARK: - Barge-in

    func testBargeInPublishesInterruptEvent() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = InfiniteStreamingStub()
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var interrupt: InterruptEvent?
        let subID = await hub.subscribe(InterruptEvent.self) { interrupt = $0 }

        await hub.publish(makeTurnEnded())
        await waitUntil { stub.callCount > 0 }

        await hub.publish(makeTurnStarted())
        await waitUntil { interrupt != nil }

        XCTAssertNotNil(interrupt)
        XCTAssertEqual(interrupt?.epoch, 1)
        await hub.unsubscribe(subID)
    }

    func testBargeInWithNoActiveCallStillPublishesInterrupt() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var interrupt: InterruptEvent?
        let subID = await hub.subscribe(InterruptEvent.self) { interrupt = $0 }

        await hub.publish(makeTurnStarted()) // No active stream
        await waitUntil { interrupt != nil }

        XCTAssertNotNil(interrupt)
        await hub.unsubscribe(subID)
    }

    func testEpochIncrementedOnEachBargeIn() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var interrupts: [InterruptEvent] = []
        let subID = await hub.subscribe(InterruptEvent.self) { interrupts.append($0) }

        await hub.publish(makeTurnStarted())
        await hub.publish(makeTurnStarted())
        await waitUntil { interrupts.count == 2 }

        XCTAssertEqual(interrupts[0].epoch, 1)
        XCTAssertEqual(interrupts[1].epoch, 2)
        await hub.unsubscribe(subID)
    }
}
