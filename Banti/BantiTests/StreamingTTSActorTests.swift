// Banti/BantiTests/StreamingTTSActorTests.swift
import XCTest
@testable import Banti

// MARK: - Stub

actor StubCartesiaWSProvider: CartesiaWebSocketProvider {
    struct SendCall { let text: String; let contextID: String; let continuing: Bool }
    private(set) var sendCalls: [SendCall] = []
    private(set) var disconnected = false
    private(set) var connectCount = 0
    private(set) var shouldThrowOnConnect = false

    func setShouldThrowOnConnect(_ value: Bool) {
        shouldThrowOnConnect = value
    }

    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    func connect() async throws -> AsyncThrowingStream<Data, Error> {
        if shouldThrowOnConnect { throw URLError(.cannotConnectToHost) }
        connectCount += 1
        // Use makeStream() so the continuation is captured synchronously — no weak-self race.
        let (stream, cont) = AsyncThrowingStream.makeStream(of: Data.self)
        continuation = cont
        return stream
    }

    func send(text: String, contextID: String, continuing: Bool) async throws {
        sendCalls.append(SendCall(text: text, contextID: contextID, continuing: continuing))
    }

    func disconnect() async {
        disconnected = true
        continuation?.finish()
    }

    func simulateAudioChunk(_ data: Data) {
        continuation?.yield(data)
    }
}

// MARK: - Tests

final class StreamingTTSActorTests: XCTestCase {

    func waitUntil(_ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while await !condition() {
            guard Date() < deadline else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func makeChunk(text: String = "Hello world.", epoch: Int = 0) -> SpeakChunkEvent {
        SpeakChunkEvent(text: text, epoch: epoch)
    }

    func makeInterrupt(epoch: Int) -> InterruptEvent {
        InterruptEvent(epoch: epoch)
    }

    // MARK: - Basic forwarding

    func testChunkForwardedToCartesia() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub)
        try await tts.start()

        await hub.publish(makeChunk(text: "Hello.", epoch: 0))
        await waitUntil { await stub.sendCalls.count == 1 }

        let call = await stub.sendCalls[0]
        XCTAssertEqual(call.text, "Hello.")
        XCTAssertTrue(call.continuing)
    }

    // MARK: - Epoch gate

    func testStaleChunkDiscarded() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub)
        try await tts.start()

        // Interrupt advances epoch to 1
        await hub.publish(makeInterrupt(epoch: 1))
        try await Task.sleep(for: .milliseconds(50))

        // Publish chunk with old epoch 0 — should be discarded
        await hub.publish(makeChunk(text: "stale", epoch: 0))
        try await Task.sleep(for: .milliseconds(200))

        let calls = await stub.sendCalls
        let flushed = calls.filter { !$0.continuing }
        XCTAssertEqual(flushed.count, 1, "Interrupt should send continue:false")
        XCTAssertFalse(calls.contains { $0.text == "stale" }, "Stale chunk should not be sent")
    }

    func testCurrentEpochChunkForwarded() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub)
        try await tts.start()

        await hub.publish(makeInterrupt(epoch: 1))
        try await Task.sleep(for: .milliseconds(50))

        await hub.publish(makeChunk(text: "fresh", epoch: 1))
        await waitUntil { await stub.sendCalls.filter({ $0.text == "fresh" }).count == 1 }

        let calls = await stub.sendCalls
        XCTAssertTrue(calls.contains { $0.text == "fresh" })
    }

    // MARK: - context_id consistency

    func testChunksForSameUtteranceShareContextID() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub)
        try await tts.start()

        await hub.publish(makeChunk(text: "First.", epoch: 0))
        await hub.publish(makeChunk(text: "Second.", epoch: 0))
        await waitUntil { await stub.sendCalls.count == 2 }

        let calls = await stub.sendCalls
        XCTAssertEqual(calls[0].contextID, calls[1].contextID, "Same utterance must share contextID")
        XCTAssertFalse(calls[0].contextID.isEmpty)
    }

    func testNewContextIDAfterInterrupt() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub)
        try await tts.start()

        await hub.publish(makeChunk(text: "Before.", epoch: 0))
        await waitUntil { await stub.sendCalls.count == 1 }
        let firstID = await stub.sendCalls[0].contextID

        await hub.publish(makeInterrupt(epoch: 1))
        try await Task.sleep(for: .milliseconds(50))

        await hub.publish(makeChunk(text: "After.", epoch: 1))
        await waitUntil { await stub.sendCalls.filter({ $0.continuing && $0.text == "After." }).count == 1 }

        let afterCall = await stub.sendCalls.first { $0.text == "After." }
        XCTAssertNotEqual(afterCall?.contextID, firstID, "New utterance needs a new contextID")
    }

    // MARK: - Interrupt sends continue:false

    func testInterruptSendsContinueFalse() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub)
        try await tts.start()

        await hub.publish(makeChunk(text: "Hello.", epoch: 0))
        await waitUntil { await stub.sendCalls.count == 1 }
        let contextID = await stub.sendCalls[0].contextID

        await hub.publish(makeInterrupt(epoch: 1))
        await waitUntil { await stub.sendCalls.contains { !$0.continuing } }

        let flushCall = await stub.sendCalls.first { !$0.continuing }
        XCTAssertEqual(flushCall?.contextID, contextID)
        XCTAssertEqual(flushCall?.text, "")
    }

    // MARK: - Health degrades on connect failure

    func testHealthDegradedOnConnectFailure() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        await stub.setShouldThrowOnConnect(true)
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub,
                                    reconnectBaseDelay: 0.01, maxReconnectDelay: 0.05)
        try await tts.start()

        // Trigger a chunk to force a connect attempt
        await hub.publish(makeChunk(text: "Hello.", epoch: 0))

        await waitUntil {
            let h = await tts.health()
            if case .degraded = h { return true }
            return false
        }

        if case .degraded = await tts.health() { /* expected */ }
        else { XCTFail("Expected .degraded after connect failure") }
    }
}
