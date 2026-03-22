import XCTest
@testable import Banti

final class TurnDetectorActorTests: XCTestCase {

    // MARK: - Helpers

    let shortSilence: TimeInterval = 0.15   // fast silence for tests

    func makeFinalSegment(text: String = "hello world") -> TranscriptSegmentEvent {
        TranscriptSegmentEvent(speakerLabel: "Speaker 0", text: text,
                               startTime: 0, endTime: 1, isFinal: true)
    }

    func makeNonFinalSegment(text: String = "hel...") -> TranscriptSegmentEvent {
        TranscriptSegmentEvent(speakerLabel: "Speaker 0", text: text,
                               startTime: 0, endTime: 1, isFinal: false)
    }

    /// Polls until condition returns true or 2s elapses.
    func waitUntil(_ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while await !condition() {
            guard Date() < deadline else { return }
            await Task.yield()
        }
    }

    // MARK: - Step 3: TurnEvent types can be published/subscribed

    func testTurnEndedEventCanBePubSubbed() async throws {
        let hub = EventHubActor()
        var received: TurnEndedEvent?
        let subID = await hub.subscribe(TurnEndedEvent.self) { event in
            received = event
        }

        let event = TurnEndedEvent(text: "test turn text")
        await hub.publish(event)

        await waitUntil { received != nil }
        XCTAssertEqual(received?.text, "test turn text")
        await hub.unsubscribe(subID)
    }

    func testTurnStartedEventCanBePubSubbed() async throws {
        let hub = EventHubActor()
        var received: TurnStartedEvent?
        let subID = await hub.subscribe(TurnStartedEvent.self) { event in
            received = event
        }

        let event = TurnStartedEvent()
        await hub.publish(event)

        await waitUntil { received != nil }
        XCTAssertNotNil(received)
        await hub.unsubscribe(subID)
    }

    // MARK: - Step 4: TurnDetectorActor behaviour

    func testTurnEndedPublishedAfterFinalSegmentAndSilence() async throws {
        let hub = EventHubActor()
        let detector = TurnDetectorActor(eventHub: hub, silenceDuration: shortSilence)
        try await detector.start()

        var received: TurnEndedEvent?
        let subID = await hub.subscribe(TurnEndedEvent.self) { event in
            received = event
        }

        await hub.publish(makeFinalSegment(text: "let's build this"))
        await waitUntil { received != nil }

        XCTAssertNotNil(received)
        await hub.unsubscribe(subID)
    }

    func testTurnEndedTextMatchesFinalSegment() async throws {
        let hub = EventHubActor()
        let detector = TurnDetectorActor(eventHub: hub, silenceDuration: shortSilence)
        try await detector.start()

        var received: TurnEndedEvent?
        let subID = await hub.subscribe(TurnEndedEvent.self) { event in
            received = event
        }

        await hub.publish(makeFinalSegment(text: "refactor this function"))
        await waitUntil { received != nil }

        XCTAssertEqual(received?.text, "refactor this function")
        await hub.unsubscribe(subID)
    }

    func testNonFinalSegmentDoesNotTriggerTurnEnd() async throws {
        let hub = EventHubActor()
        let detector = TurnDetectorActor(eventHub: hub, silenceDuration: shortSilence)
        try await detector.start()

        var received: TurnEndedEvent?
        let subID = await hub.subscribe(TurnEndedEvent.self) { event in
            received = event
        }

        await hub.publish(makeNonFinalSegment(text: "hel..."))
        // Wait longer than silence duration — nothing should arrive
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(received)
        await hub.unsubscribe(subID)
    }

    func testEmptyFinalSegmentDoesNotTriggerTurnEnd() async throws {
        let hub = EventHubActor()
        let detector = TurnDetectorActor(eventHub: hub, silenceDuration: shortSilence)
        try await detector.start()

        var received: TurnEndedEvent?
        let subID = await hub.subscribe(TurnEndedEvent.self) { event in
            received = event
        }

        await hub.publish(makeFinalSegment(text: ""))
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(received)
        await hub.unsubscribe(subID)
    }

    func testMultipleFinalSegmentsAccumulatedIntoOneTurn() async throws {
        let hub = EventHubActor()
        let detector = TurnDetectorActor(eventHub: hub, silenceDuration: shortSilence)
        try await detector.start()

        var events: [TurnEndedEvent] = []
        let subID = await hub.subscribe(TurnEndedEvent.self) { event in
            events.append(event)
        }

        // Two finals close together — both should land before silence fires
        await hub.publish(makeFinalSegment(text: "hello"))
        await hub.publish(makeFinalSegment(text: "world"))

        // Wait for the one turn-end
        await waitUntil { events.count == 1 }
        // Give a bit more time to ensure no second event fires
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.text, "hello world")
        await hub.unsubscribe(subID)
    }

    func testTurnStartedPublishedOnFirstFinalSegment() async throws {
        let hub = EventHubActor()
        let detector = TurnDetectorActor(eventHub: hub, silenceDuration: shortSilence)
        try await detector.start()

        var started: TurnStartedEvent?
        let subID = await hub.subscribe(TurnStartedEvent.self) { event in
            started = event
        }

        await hub.publish(makeFinalSegment(text: "start of turn"))
        await waitUntil { started != nil }

        XCTAssertNotNil(started)
        await hub.unsubscribe(subID)
    }
}
