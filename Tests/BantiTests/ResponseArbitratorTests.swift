// Tests/BantiTests/ResponseArbitratorTests.swift
import XCTest
@testable import BantiCore

final class ResponseArbitratorTests: XCTestCase {

    func testPublishesSpeechPlanFromAllResponses() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "motor.speech_plan") { event in
            await received.append(event)
        }

        let arbitrator = ResponseArbitrator(
            cerebras: { _, _, _, _ in "{\"sentences\":[\"Hey!\",\"Did you fix that bug?\"]}" },
            collectionWindowMs: 200
        )
        await arbitrator.start(bus: bus)

        // First publish the route so arbitrator knows which tracks to expect
        let episode = EpisodePayload(text: "test", participants: [], emotionalTone: "neutral")
        let route = BrainRoutePayload(tracks: ["brainstem", "prefrontal"], reason: "test", episode: episode)
        await bus.publish(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(route)),
            topic: "brain.route"
        )

        // Then publish brainstem response
        let r = BrainResponsePayload(track: "brainstem", text: "Hey!", activatedTracks: ["brainstem", "prefrontal"])
        await bus.publish(
            BantiEvent(source: "brainstem", topic: "brain.brainstem.response", surprise: 0,
                       payload: .brainResponse(r)),
            topic: "brain.brainstem.response"
        )

        try? await Task.sleep(nanoseconds: 400_000_000) // wait for window

        let events = await received.value
        XCTAssertEqual(events.count, 1)
        if case .speechPlan(let plan) = events.first?.payload {
            XCTAssertFalse(plan.sentences.isEmpty)
        } else { XCTFail() }
    }

    func testPublishesEmptyPlanOnTimeout() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "motor.speech_plan") { event in
            await received.append(event)
        }

        let arbitrator = ResponseArbitrator(
            cerebras: { _, _, _, _ in "{\"sentences\":[]}" },
            collectionWindowMs: 150
        )
        await arbitrator.start(bus: bus)

        // Publish route but NO responses — should still publish empty plan after window
        let episode = EpisodePayload(text: "test", participants: [], emotionalTone: "neutral")
        let route = BrainRoutePayload(tracks: ["brainstem"], reason: "test", episode: episode)
        await bus.publish(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(route)),
            topic: "brain.route"
        )
        try? await Task.sleep(nanoseconds: 400_000_000)

        let events = await received.value
        XCTAssertEqual(events.count, 1, "should publish empty plan as fallback")
        if case .speechPlan(let plan) = events.first?.payload {
            XCTAssertTrue(plan.sentences.isEmpty)
        }
    }
}
