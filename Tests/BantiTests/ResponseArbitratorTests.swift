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
        let r = BrainResponsePayload(track: "brainstem", text: "Hey!",
                                     activatedTracks: ["brainstem", "prefrontal"],
                                     episodeID: episode.episodeID)
        await bus.publish(
            BantiEvent(source: "brainstem", topic: "brain.brainstem.response", surprise: 0,
                       payload: .brainResponse(r)),
            topic: "brain.brainstem.response"
        )

        let p = BrainResponsePayload(track: "prefrontal", text: "Did you fix that bug?",
                                     activatedTracks: ["brainstem", "prefrontal"],
                                     episodeID: episode.episodeID)
        await bus.publish(
            BantiEvent(source: "prefrontal", topic: "brain.prefrontal.response", surprise: 0,
                       payload: .brainResponse(p)),
            topic: "brain.prefrontal.response"
        )

        try? await Task.sleep(nanoseconds: 150_000_000)

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

    func testIgnoresStaleResponsesFromPreviousRoute() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "motor.speech_plan") { event in
            await received.append(event)
        }

        let arbitrator = ResponseArbitrator(
            cerebras: { _, _, userContent, _ in
                let sanitized = userContent.replacingOccurrences(of: "\n", with: " | ")
                return "{\"sentences\":[\"\(sanitized)\"]}"
            },
            collectionWindowMs: 300
        )
        await arbitrator.start(bus: bus)

        let oldEpisode = EpisodePayload(text: "first episode", participants: [], emotionalTone: "neutral")
        let oldRoute = BrainRoutePayload(tracks: ["brainstem"], reason: "old", episode: oldEpisode)
        await arbitrator.handle(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(oldRoute))
        )

        let newEpisode = EpisodePayload(text: "second episode", participants: [], emotionalTone: "neutral")
        let newRoute = BrainRoutePayload(tracks: ["brainstem"], reason: "new", episode: newEpisode)
        await arbitrator.handle(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(newRoute))
        )

        let stale = BrainResponsePayload(track: "brainstem", text: "stale response",
                                         activatedTracks: ["brainstem"],
                                         episodeID: oldEpisode.episodeID)
        await arbitrator.handle(
            BantiEvent(source: "brainstem", topic: "brain.brainstem.response", surprise: 0,
                       payload: .brainResponse(stale))
        )

        try? await Task.sleep(nanoseconds: 100_000_000)
        let staleEvents = await received.value
        XCTAssertEqual(staleEvents.count, 0, "stale response should not satisfy the new route")

        let current = BrainResponsePayload(track: "brainstem", text: "current response",
                                           activatedTracks: ["brainstem"],
                                           episodeID: newEpisode.episodeID)
        await arbitrator.handle(
            BantiEvent(source: "brainstem", topic: "brain.brainstem.response", surprise: 0,
                       payload: .brainResponse(current))
        )

        try? await Task.sleep(nanoseconds: 200_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 1)
        if case .speechPlan(let plan) = events.first?.payload {
            XCTAssertEqual(plan.sentences.count, 1)
            XCTAssertTrue(plan.sentences[0].contains("current response"))
            XCTAssertFalse(plan.sentences[0].contains("stale response"))
        } else {
            XCTFail("expected speech plan payload")
        }
    }

    func testIgnoresLateStaleResponseAfterNewEpisodeFlushes() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "motor.speech_plan") { event in
            await received.append(event)
        }

        let arbitrator = ResponseArbitrator(
            cerebras: { _, _, userContent, _ in
                let sanitized = userContent.replacingOccurrences(of: "\n", with: " | ")
                return "{\"sentences\":[\"\(sanitized)\"]}"
            },
            collectionWindowMs: 300
        )
        await arbitrator.start(bus: bus)

        let oldEpisode = EpisodePayload(text: "first episode", participants: [], emotionalTone: "neutral")
        let oldRoute = BrainRoutePayload(tracks: ["brainstem"], reason: "old", episode: oldEpisode)
        await arbitrator.handle(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(oldRoute))
        )

        let newEpisode = EpisodePayload(text: "second episode", participants: [], emotionalTone: "neutral")
        let newRoute = BrainRoutePayload(tracks: ["brainstem"], reason: "new", episode: newEpisode)
        await arbitrator.handle(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(newRoute))
        )

        let current = BrainResponsePayload(track: "brainstem", text: "current response",
                                           activatedTracks: ["brainstem"],
                                           episodeID: newEpisode.episodeID)
        await arbitrator.handle(
            BantiEvent(source: "brainstem", topic: "brain.brainstem.response", surprise: 0,
                       payload: .brainResponse(current))
        )

        try? await Task.sleep(nanoseconds: 100_000_000)
        let firstEvents = await received.value
        XCTAssertEqual(firstEvents.count, 1)

        let stale = BrainResponsePayload(track: "brainstem", text: "stale response",
                                         activatedTracks: ["brainstem"],
                                         episodeID: oldEpisode.episodeID)
        await arbitrator.handle(
            BantiEvent(source: "brainstem", topic: "brain.brainstem.response", surprise: 0,
                       payload: .brainResponse(stale))
        )

        try? await Task.sleep(nanoseconds: 150_000_000)
        let finalEvents = await received.value
        XCTAssertEqual(finalEvents.count, 1, "late stale response should be ignored after the new episode flushes")
        if case .speechPlan(let plan) = finalEvents.first?.payload {
            XCTAssertTrue(plan.sentences[0].contains("current response"))
            XCTAssertFalse(plan.sentences[0].contains("stale response"))
        } else {
            XCTFail("expected speech plan payload")
        }
    }

    func testIgnoresDuplicateResponseAfterEpisodeAlreadyFlushed() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "motor.speech_plan") { event in
            await received.append(event)
        }

        let arbitrator = ResponseArbitrator(
            cerebras: { _, _, userContent, _ in
                let sanitized = userContent.replacingOccurrences(of: "\n", with: " | ")
                return "{\"sentences\":[\"\(sanitized)\"]}"
            },
            collectionWindowMs: 300
        )
        await arbitrator.start(bus: bus)

        let episode = EpisodePayload(text: "single episode", participants: [], emotionalTone: "neutral")
        let route = BrainRoutePayload(tracks: ["brainstem"], reason: "single", episode: episode)
        await arbitrator.handle(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(route))
        )

        let response = BrainResponsePayload(track: "brainstem", text: "first response",
                                            activatedTracks: ["brainstem"],
                                            episodeID: episode.episodeID)
        await arbitrator.handle(
            BantiEvent(source: "brainstem", topic: "brain.brainstem.response", surprise: 0,
                       payload: .brainResponse(response))
        )

        try? await Task.sleep(nanoseconds: 100_000_000)
        let firstEvents = await received.value
        XCTAssertEqual(firstEvents.count, 1)

        let duplicate = BrainResponsePayload(track: "brainstem", text: "duplicate response",
                                             activatedTracks: ["brainstem"],
                                             episodeID: episode.episodeID)
        await arbitrator.handle(
            BantiEvent(source: "brainstem", topic: "brain.brainstem.response", surprise: 0,
                       payload: .brainResponse(duplicate))
        )

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 1, "duplicate response after flush should be ignored")
        if case .speechPlan(let plan) = events.first?.payload {
            XCTAssertTrue(plan.sentences[0].contains("first response"))
            XCTAssertFalse(plan.sentences[0].contains("duplicate response"))
        } else {
            XCTFail("expected speech plan payload")
        }
    }

    func testIgnoresOutOfOrderOlderRouteAfterNewerRoute() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "motor.speech_plan") { event in
            await received.append(event)
        }

        let arbitrator = ResponseArbitrator(
            cerebras: { _, _, userContent, _ in
                let sanitized = userContent.replacingOccurrences(of: "\n", with: " | ")
                return "{\"sentences\":[\"\(sanitized)\"]}"
            },
            collectionWindowMs: 300
        )
        await arbitrator.start(bus: bus)

        let newEpisode = EpisodePayload(text: "new episode", participants: [], emotionalTone: "neutral", timestampNs: 2)
        let newRoute = BrainRoutePayload(tracks: ["brainstem"], reason: "new", episode: newEpisode)
        await arbitrator.handle(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(newRoute))
        )

        let oldEpisode = EpisodePayload(text: "old episode", participants: [], emotionalTone: "neutral", timestampNs: 1)
        let oldRoute = BrainRoutePayload(tracks: ["brainstem"], reason: "old", episode: oldEpisode)
        await arbitrator.handle(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(oldRoute))
        )

        let current = BrainResponsePayload(track: "brainstem", text: "current response",
                                           activatedTracks: ["brainstem"],
                                           episodeID: newEpisode.episodeID)
        await arbitrator.handle(
            BantiEvent(source: "brainstem", topic: "brain.brainstem.response", surprise: 0,
                       payload: .brainResponse(current))
        )

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 1, "older route should not supersede the newer route")
        if case .speechPlan(let plan) = events.first?.payload {
            XCTAssertTrue(plan.sentences[0].contains("current response"))
        } else {
            XCTFail("expected speech plan payload")
        }
    }
}
