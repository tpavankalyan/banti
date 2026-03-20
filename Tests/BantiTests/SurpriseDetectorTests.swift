// Tests/BantiTests/SurpriseDetectorTests.swift
import XCTest
@testable import BantiCore

final class SurpriseDetectorTests: XCTestCase {

    func testHighSurpriseForwardsEvent() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "gate.surprise") { event in
            await received.append(event)
        }

        // Mock Cerebras returns score 0.8 — above threshold
        let detector = SurpriseDetector(cerebras: mockCerebras(score: 0.8))
        await detector.start(bus: bus)

        await bus.publish(makeSpeechEvent(), topic: "sensor.audio")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 1)
        XCTAssertGreaterThanOrEqual(events.first?.surprise ?? 0, 0.3)
    }

    func testLowSurpriseDropsEvent() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "gate.surprise") { event in
            await received.append(event)
        }

        let detector = SurpriseDetector(cerebras: mockCerebras(score: 0.1))
        await detector.start(bus: bus)

        await bus.publish(makeSpeechEvent(), topic: "sensor.audio")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 0)
    }

    func testCerebrasErrorDropsEvent() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "gate.surprise") { event in
            await received.append(event)
        }

        let detector = SurpriseDetector(cerebras: { _, _, _, _ in throw URLError(.notConnectedToInternet) })
        await detector.start(bus: bus)

        await bus.publish(makeSpeechEvent(), topic: "sensor.audio")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 0, "errors should be swallowed silently")
    }

    // MARK: - Helpers

    private func mockCerebras(score: Float) -> CerebrasCompletion {
        { _, _, _, _ in "{\"surprise\": \(score)}" }
    }

    private func makeSpeechEvent() -> BantiEvent {
        BantiEvent(source: "audio_cortex", topic: "sensor.audio", surprise: 0,
                   payload: .speechDetected(SpeechPayload(transcript: "hello world", speakerID: nil)))
    }
}
