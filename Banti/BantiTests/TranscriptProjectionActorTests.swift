import XCTest
@testable import Banti

final class TranscriptProjectionActorTests: XCTestCase {
    func testFinalResultPublishesSegment() async {
        let hub = EventHubActor()
        let projection = TranscriptProjectionActor(eventHub: hub)
        let exp = XCTestExpectation(description: "segment received")
        var segment: TranscriptSegmentEvent?

        _ = await hub.subscribe(TranscriptSegmentEvent.self) { event in
            segment = event
            exp.fulfill()
        }

        try? await projection.start()

        await hub.publish(RawTranscriptEvent(
            text: "hello", speakerIndex: 0, confidence: 0.95,
            isFinal: true, audioStartTime: 0.0, audioEndTime: 1.0
        ))
        await fulfillment(of: [exp], timeout: 2)

        XCTAssertEqual(segment?.text, "hello")
        XCTAssertEqual(segment?.speakerLabel, "Speaker 1")
        XCTAssertTrue(segment?.isFinal ?? false)
    }

    func testSpeakerMappingIsStable() async {
        let hub = EventHubActor()
        let projection = TranscriptProjectionActor(eventHub: hub)
        var segments: [TranscriptSegmentEvent] = []
        let exp = XCTestExpectation(description: "two segments")
        exp.expectedFulfillmentCount = 2

        _ = await hub.subscribe(TranscriptSegmentEvent.self) { event in
            if event.isFinal {
                segments.append(event)
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
        XCTAssertEqual(segments[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(segments[1].speakerLabel, "Speaker 2")
    }

    func testInterimResultsPublishNonFinal() async {
        let hub = EventHubActor()
        let projection = TranscriptProjectionActor(eventHub: hub)
        let exp = XCTestExpectation(description: "interim segment")
        var segment: TranscriptSegmentEvent?

        _ = await hub.subscribe(TranscriptSegmentEvent.self) { event in
            segment = event
            exp.fulfill()
        }

        try? await projection.start()

        await hub.publish(RawTranscriptEvent(
            text: "hel", speakerIndex: 0, confidence: 0.5,
            isFinal: false, audioStartTime: 0, audioEndTime: 0.5
        ))

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertFalse(segment?.isFinal ?? true)
        XCTAssertEqual(segment?.text, "hel")
    }

    func testTimestampDedup() async {
        let hub = EventHubActor()
        let projection = TranscriptProjectionActor(eventHub: hub)
        var finalSegments: [TranscriptSegmentEvent] = []

        _ = await hub.subscribe(TranscriptSegmentEvent.self) { event in
            if event.isFinal { finalSegments.append(event) }
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
        XCTAssertEqual(finalSegments.count, 1)
    }
}
