// Tests/BantiTests/BrainstemNodeTests.swift
import XCTest
@testable import BantiCore

final class BrainstemNodeTests: XCTestCase {

    func testPublishesResponseWhenActivated() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "brain.brainstem.response") { event in
            await received.append(event)
        }

        let node = BrainstemNode(cerebras: { _, _, _, _ in "Hey Pavan! How are you?" })
        await node.start(bus: bus)

        let route = BrainRoutePayload(
            tracks: ["brainstem"],
            reason: "speech",
            episode: EpisodePayload(text: "hello", participants: ["Pavan"], emotionalTone: "warm")
        )
        await bus.publish(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(route)),
            topic: "brain.route"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        let events = await received.value
        XCTAssertEqual(events.count, 1)
        if case .brainResponse(let r) = events.first?.payload {
            XCTAssertEqual(r.track, "brainstem")
            XCTAssertEqual(r.text, "Hey Pavan! How are you?")
            XCTAssertTrue(r.activatedTracks.contains("brainstem"))
        } else { XCTFail() }
    }

    func testDoesNotRespondWhenNotActivated() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "brain.brainstem.response") { event in
            await received.append(event)
        }

        let node = BrainstemNode(cerebras: { _, _, _, _ in "hello" })
        await node.start(bus: bus)

        // Route only activates limbic — not brainstem
        let route = BrainRoutePayload(
            tracks: ["limbic"],
            reason: "emotion only",
            episode: EpisodePayload(text: "sad face", participants: [], emotionalTone: "sad")
        )
        await bus.publish(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(route)),
            topic: "brain.route"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 0)
    }

    func testSilentResponseIsDropped() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "brain.brainstem.response") { event in
            await received.append(event)
        }

        let node = BrainstemNode(cerebras: { _, _, _, _ in "[silent]" })
        await node.start(bus: bus)

        let route = BrainRoutePayload(
            tracks: ["brainstem"], reason: "heartbeat",
            episode: EpisodePayload(text: "quiet room", participants: [], emotionalTone: "neutral")
        )
        await bus.publish(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 0.3,
                       payload: .brainRoute(route)),
            topic: "brain.route"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        let silentEvents = await received.value
        XCTAssertEqual(silentEvents.count, 0, "[silent] should not publish a response")
    }
}
