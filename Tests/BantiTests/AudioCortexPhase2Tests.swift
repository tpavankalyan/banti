// Tests/BantiTests/AudioCortexPhase2Tests.swift
import XCTest
@testable import BantiCore

final class AudioCortexPhase2Tests: XCTestCase {

    func testSuppressesMicWhileSpeaking() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "sensor.audio") { event in
            await received.append(event)
        }

        let cortex = AudioCortex(deepgram: nil, hume: nil, bus: bus)
        await cortex.start(bus: bus)

        // Signal that Banti started speaking
        await bus.publish(
            BantiEvent(source: "banti_voice", topic: "motor.voice", surprise: 0,
                       payload: .voiceSpeaking(VoiceSpeakingPayload(speaking: true,
                           estimatedDurationMs: 1000, tailWindowMs: 5000,
                           text: "hello friend"))),
            topic: "motor.voice"
        )
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Simulate transcript arriving during speaking — should be suppressed
        await cortex.injectTranscriptForTest("hello friend") // self-echo
        try? await Task.sleep(nanoseconds: 50_000_000)
        let count = await received.value.count
        XCTAssertEqual(count, 0, "transcript during speaking should be suppressed")
    }

    func testPassesThroughAfterTailWindow() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "sensor.audio") { event in
            if case .speechDetected = event.payload { await received.append(event) }
        }

        let cortex = AudioCortex(deepgram: nil, hume: nil, bus: bus)
        await cortex.start(bus: bus)

        // Signal stop (never started — tail window is 50ms for test)
        await cortex.setTailWindowMsForTest(50)
        await bus.publish(
            BantiEvent(source: "banti_voice", topic: "motor.voice", surprise: 0,
                       payload: .voiceSpeaking(VoiceSpeakingPayload(speaking: false,
                           estimatedDurationMs: 0, tailWindowMs: 50, text: nil))),
            topic: "motor.voice"
        )
        try? await Task.sleep(nanoseconds: 100_000_000) // wait past tail window

        await cortex.injectTranscriptForTest("different content")
        try? await Task.sleep(nanoseconds: 50_000_000)
        let count = await received.value.count
        XCTAssertEqual(count, 1, "non-echo transcript after tail window should pass through")
    }
}
