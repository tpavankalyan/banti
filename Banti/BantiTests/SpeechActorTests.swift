import XCTest
@testable import Banti

final class SpeechActorTests: XCTestCase {
    func testSynthesizesAndPlaysAudioOnBrainResponse() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: """
        CARTESIA_API_KEY=test-key
        CARTESIA_VOICE_ID=test-voice
        """)
        let synthesized = TestRecorder<String>()
        let played = TestRecorder<Int>()
        let doneExpectation = XCTestExpectation(description: "playback done")

        let speech = SpeechActor(
            eventHub: hub,
            config: config,
            synthesizeAudio: { text in
                await synthesized.append(text)
                return Data([0x01, 0x02, 0x03])
            },
            playAudio: { data in
                await played.append(data.count)
                doneExpectation.fulfill()
            }
        )

        try await speech.start()
        await hub.publish(BrainResponseEvent(text: "hello pavan"))

        await fulfillment(of: [doneExpectation], timeout: 2)
        let synthSnapshot = await synthesized.snapshot()
        let playSnapshot = await played.snapshot()
        XCTAssertEqual(synthSnapshot, ["hello pavan"])
        XCTAssertEqual(playSnapshot, [3])
    }
}
