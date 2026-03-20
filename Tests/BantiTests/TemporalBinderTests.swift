// Tests/BantiTests/TemporalBinderTests.swift
import XCTest
@testable import BantiCore

final class TemporalBinderTests: XCTestCase {

    func testWindowClosesAfter500msAndPublishesEpisode() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "episode.bound") { event in
            await received.append(event)
        }

        let binder = TemporalBinder(cerebras: { _, _, _, _ in
            """
            {"text":"Pavan said hello","participants":["Pavan"],"emotionalTone":"warm"}
            """
        }, windowMs: 200) // short window for test speed
        await binder.start(bus: bus)

        // Publish one surprise event
        await bus.publish(makeSurpriseEvent("sensor.audio"), topic: "gate.surprise")

        // Wait >200ms for window to close
        try? await Task.sleep(nanoseconds: 400_000_000)

        let events = await received.value
        XCTAssertEqual(events.count, 1)
        if case .episodeBound(let ep) = events.first?.payload {
            XCTAssertEqual(ep.text, "Pavan said hello")
            XCTAssertEqual(ep.participants, ["Pavan"])
        } else {
            XCTFail("expected episodeBound payload")
        }
    }

    func testNewEventResetsWindow() async {
        // If two events arrive 100ms apart with a 200ms window,
        // the episode should only publish once, 200ms after the second event.
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "episode.bound") { event in
            await received.append(event)
        }

        let binder = TemporalBinder(cerebras: { _, _, _, _ in
            "{\"text\":\"test\",\"participants\":[],\"emotionalTone\":\"neutral\"}"
        }, windowMs: 200)
        await binder.start(bus: bus)

        await bus.publish(makeSurpriseEvent("sensor.audio"), topic: "gate.surprise")
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms — within window
        await bus.publish(makeSurpriseEvent("sensor.visual"), topic: "gate.surprise")
        try? await Task.sleep(nanoseconds: 350_000_000) // 350ms — window closes

        let events = await received.value
        XCTAssertEqual(events.count, 1, "debounce should produce exactly one episode")
    }

    func testMarkdownWrappedJSONStillPublishesEpisode() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "episode.bound") { event in
            await received.append(event)
        }

        let binder = TemporalBinder(cerebras: { _, _, _, _ in
            """
            ### JSON Output
            ```json
            {
              "text": "Wrapped response",
              "participants": ["Alex"],
              "emotionalTone": "calm"
            }
            ```
            """
        }, windowMs: 100)
        await binder.start(bus: bus)

        await bus.publish(makeSurpriseEvent("sensor.audio"), topic: "gate.surprise")
        try? await Task.sleep(nanoseconds: 250_000_000)

        let events = await received.value
        XCTAssertEqual(events.count, 1, "markdown-wrapped JSON should still decode")
        if case .episodeBound(let episode) = events.first?.payload {
            XCTAssertEqual(episode.text, "Wrapped response")
            XCTAssertEqual(episode.participants, ["Alex"])
            XCTAssertEqual(episode.emotionalTone, "calm")
        } else {
            XCTFail("expected episodeBound payload")
        }
    }

    private func makeSurpriseEvent(_ topic: String) -> BantiEvent {
        BantiEvent(source: "test", topic: topic, surprise: 0.9,
                   payload: .speechDetected(SpeechPayload(transcript: "hi", speakerID: nil)))
    }
}
