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

    func testDifferentTopicsDoNotThrottleEachOther() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "gate.surprise") { event in
            await received.append(event)
        }

        let detector = SurpriseDetector(cerebras: mockCerebras(score: 0.8))
        await detector.start(bus: bus)

        await bus.publish(makeSpeechEvent(), topic: "sensor.audio")
        let screen = BantiEvent(
            source: "screen_cortex",
            topic: "sensor.visual",
            surprise: 0,
            payload: .screenUpdate(ScreenPayload(ocrLines: ["docs"], interpretation: "editing code"))
        )
        await bus.publish(screen, topic: "sensor.visual")

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 2, "audio and visual events should be throttled independently")
    }

    func testSameTopicRecoversAfterFailedCall() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "gate.surprise") { event in
            await received.append(event)
        }

        let attempts = Counter()
        let detector = SurpriseDetector(cerebras: { _, _, _, _ in
            let current = await attempts.next()
            if current == 0 {
                throw URLError(.notConnectedToInternet)
            }
            return "{\"surprise\": 0.8}"
        })
        await detector.start(bus: bus)

        await bus.publish(makeSpeechEvent(), topic: "sensor.audio")
        try? await Task.sleep(nanoseconds: 50_000_000)
        await bus.publish(makeSpeechEvent(), topic: "sensor.audio")

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 1, "a failed same-topic call should not consume the cooldown")
    }

    func testSpeechAndAudioEmotionDoNotThrottleEachOther() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "gate.surprise") { event in
            await received.append(event)
        }

        let detector = SurpriseDetector(cerebras: mockCerebras(score: 0.8))
        await detector.start(bus: bus)

        await bus.publish(makeSpeechEvent(), topic: "sensor.audio")
        let emotion = BantiEvent(
            source: "audio_cortex",
            topic: "sensor.audio",
            surprise: 0,
            payload: .emotionUpdate(EmotionPayload(emotions: [.init(label: "joy", score: 0.8)],
                                                   source: "hume_voice"))
        )
        await bus.publish(emotion, topic: "sensor.audio")

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 2, "speech and voice-emotion updates should be throttled independently")
    }

    func testSpeechAndAudioEmotionUseIndependentHistory() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "gate.surprise") { event in
            await received.append(event)
        }

        let detector = SurpriseDetector(cerebras: { _, _, userContent, _ in
            if userContent.contains("Speech: hello world") && userContent.contains("Previous: (nothing)") {
                return "{\"surprise\": 0.8}"
            }
            if userContent.contains("Emotion: joy 0.8") && userContent.contains("Previous: (nothing)") {
                return "{\"surprise\": 0.8}"
            }
            return "{\"surprise\": 0.1}"
        })
        await detector.start(bus: bus)

        await bus.publish(makeSpeechEvent(), topic: "sensor.audio")
        let emotion = BantiEvent(
            source: "audio_cortex",
            topic: "sensor.audio",
            surprise: 0,
            payload: .emotionUpdate(EmotionPayload(emotions: [.init(label: "joy", score: 0.8)],
                                                   source: "hume_voice"))
        )
        await bus.publish(emotion, topic: "sensor.audio")

        try? await Task.sleep(nanoseconds: 150_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 2, "speech and emotion streams should not share the same history baseline")
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

private actor Counter {
    private var value = 0

    func next() -> Int {
        let current = value
        value += 1
        return current
    }
}
