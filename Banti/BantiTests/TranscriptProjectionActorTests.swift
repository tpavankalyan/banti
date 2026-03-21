import XCTest
@testable import Banti

final class TranscriptProjectionActorTests: XCTestCase {
    func testFinalResultPublishesSegment() async {
        let hub = EventHubActor()
        let projection = TranscriptProjectionActor(eventHub: hub)
        let exp = XCTestExpectation(description: "segment received")
        let segments = TestRecorder<TranscriptSegmentEvent>()

        _ = await hub.subscribe(TranscriptSegmentEvent.self) { event in
            await segments.append(event)
            exp.fulfill()
        }

        try? await projection.start()

        await hub.publish(RawTranscriptEvent(
            text: "hello", speakerIndex: 0, confidence: 0.95,
            isFinal: true, audioStartTime: 0.0, audioEndTime: 1.0
        ))
        await fulfillment(of: [exp], timeout: 2)

        let snapshot = await segments.snapshot()
        XCTAssertEqual(snapshot.last?.text, "hello")
        XCTAssertEqual(snapshot.last?.speakerLabel, "Speaker 1")
        XCTAssertTrue(snapshot.last?.isFinal ?? false)
    }

    func testSpeakerMappingIsStable() async {
        let hub = EventHubActor()
        let projection = TranscriptProjectionActor(eventHub: hub)
        let segments = TestRecorder<TranscriptSegmentEvent>()
        let exp = XCTestExpectation(description: "two segments")
        exp.expectedFulfillmentCount = 2

        _ = await hub.subscribe(TranscriptSegmentEvent.self) { event in
            if event.isFinal {
                await segments.append(event)
                exp.fulfill()
            }
        }

        try? await projection.start()

        await hub.publish(RawTranscriptEvent(
            text: "first", speakerIndex: 0, confidence: 0.9,
            isFinal: true, audioStartTime: 0, audioEndTime: 1
        ))
        await hub.publish(RawTranscriptEvent(
            text: "second", speakerIndex: 1, confidence: 0.9,
            isFinal: true, audioStartTime: 1, audioEndTime: 2
        ))

        await fulfillment(of: [exp], timeout: 2)
        let snapshot = await segments.snapshot()
        XCTAssertEqual(snapshot[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(snapshot[1].speakerLabel, "Speaker 2")
    }

    func testInterimResultsPublishNonFinal() async {
        let hub = EventHubActor()
        let projection = TranscriptProjectionActor(eventHub: hub)
        let exp = XCTestExpectation(description: "interim segment")
        let segments = TestRecorder<TranscriptSegmentEvent>()

        _ = await hub.subscribe(TranscriptSegmentEvent.self) { event in
            await segments.append(event)
            exp.fulfill()
        }

        try? await projection.start()

        await hub.publish(RawTranscriptEvent(
            text: "hel", speakerIndex: 0, confidence: 0.5,
            isFinal: false, audioStartTime: 0, audioEndTime: 0.5
        ))

        await fulfillment(of: [exp], timeout: 2)
        let snapshot = await segments.snapshot()
        XCTAssertFalse(snapshot.last?.isFinal ?? true)
        XCTAssertEqual(snapshot.last?.text, "hel")
    }

    func testTimestampDedup() async {
        let hub = EventHubActor()
        let projection = TranscriptProjectionActor(eventHub: hub)
        let finalSegments = TestRecorder<TranscriptSegmentEvent>()

        _ = await hub.subscribe(TranscriptSegmentEvent.self) { event in
            if event.isFinal { await finalSegments.append(event) }
        }

        try? await projection.start()

        await hub.publish(RawTranscriptEvent(
            text: "hello", speakerIndex: 0, confidence: 0.9,
            isFinal: true, audioStartTime: 0, audioEndTime: 1
        ))
        await hub.publish(RawTranscriptEvent(
            text: "hello", speakerIndex: 0, confidence: 0.9,
            isFinal: true, audioStartTime: 0.5, audioEndTime: 1
        ))

        try? await Task.sleep(for: .milliseconds(300))
        let snapshot = await finalSegments.snapshot()
        XCTAssertEqual(snapshot.count, 1)
    }
}

final class MicrophoneCaptureActorTests: XCTestCase {
    func testVoiceProcessingIsDisabledByDefault() {
        let capture = MicrophoneCaptureActor(eventHub: EventHubActor())

        XCTAssertFalse(capture.voiceProcessingEnabled)
    }

    func testVoiceProcessingCanBeExplicitlyEnabled() {
        let capture = MicrophoneCaptureActor(
            eventHub: EventHubActor(),
            voiceProcessingEnabled: true
        )

        XCTAssertTrue(capture.voiceProcessingEnabled)
    }
}
