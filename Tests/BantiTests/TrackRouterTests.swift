// Tests/BantiTests/TrackRouterTests.swift
import XCTest
@testable import BantiCore

final class TrackRouterTests: XCTestCase {

    func testRoutesSpeechToBrainstemAndPrefrontal() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "brain.route") { event in
            await received.append(event)
        }

        let router = TrackRouter(cerebras: { _, _, _, _ in
            "{\"tracks\":[\"brainstem\",\"prefrontal\"],\"reason\":\"speech detected\"}"
        })
        await router.start(bus: bus)

        let episode = EpisodePayload(text: "Pavan said hello", participants: ["Pavan"],
                                     emotionalTone: "warm")
        await bus.publish(
            BantiEvent(source: "temporal_binder", topic: "episode.bound", surprise: 1.0,
                       payload: .episodeBound(episode)),
            topic: "episode.bound"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        let events = await received.value
        XCTAssertEqual(events.count, 1)
        if case .brainRoute(let route) = events.first?.payload {
            XCTAssertTrue(route.tracks.contains("brainstem"))
            XCTAssertTrue(route.tracks.contains("prefrontal"))
        } else { XCTFail() }
    }

    func testUnknownPersonTriggersBrainstem() async {
        let bus = EventBus()
        let router = TrackRouter(cerebras: { _, _, _, _ in
            "{\"tracks\":[\"brainstem\"],\"reason\":\"unknown person\"}"
        })
        await router.start(bus: bus)
        // Verify subscribedTopics includes sensor.visual
        let topics = await router.subscribedTopics
        XCTAssertTrue(topics.contains("sensor.visual"))
    }
}
