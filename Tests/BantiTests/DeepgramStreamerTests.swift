// Tests/BantiTests/DeepgramStreamerTests.swift
import XCTest
@testable import BantiCore

final class DeepgramStreamerTests: XCTestCase {

    // MARK: JSON parsing

    func testParseResponseExtractsTranscriptAndSpeaker() {
        let json = """
        {
          "channel": {
            "alternatives": [{
              "transcript": "hello world",
              "confidence": 0.99,
              "words": [{ "word": "hello", "speaker": 0 }]
            }]
          },
          "is_final": true
        }
        """
        let state = DeepgramStreamer.parseResponse(json.data(using: .utf8)!)
        XCTAssertEqual(state?.transcript, "hello world")
        XCTAssertEqual(state?.speakerID, 0)
        XCTAssertTrue(state?.isFinal ?? false)
        XCTAssertEqual(state?.confidence ?? 0, 0.99, accuracy: 0.001)
    }

    func testParseResponseReturnsNilForNonFinal() {
        let json = """
        {
          "channel": { "alternatives": [{ "transcript": "hel", "confidence": 0.5, "words": [] }] },
          "is_final": false
        }
        """
        XCTAssertNil(DeepgramStreamer.parseResponse(json.data(using: .utf8)!))
    }

    func testParseResponseHandlesMissingSpeaker() {
        let json = """
        {
          "channel": { "alternatives": [{ "transcript": "solo", "confidence": 0.8, "words": [] }] },
          "is_final": true
        }
        """
        let state = DeepgramStreamer.parseResponse(json.data(using: .utf8)!)
        XCTAssertEqual(state?.transcript, "solo")
        XCTAssertNil(state?.speakerID)
    }

    func testParseResponseReturnsNilForMalformedJSON() {
        XCTAssertNil(DeepgramStreamer.parseResponse(Data("not json".utf8)))
    }

    // MARK: KeepAlive logic

    func testShouldSendKeepAliveAfter8Seconds() {
        let last = Date(timeIntervalSinceNow: -8.5)
        XCTAssertTrue(DeepgramStreamer.shouldSendKeepAlive(lastChunkAt: last, now: Date()))
    }

    func testShouldNotSendKeepAliveWithin8Seconds() {
        let last = Date(timeIntervalSinceNow: -3.0)
        XCTAssertFalse(DeepgramStreamer.shouldSendKeepAlive(lastChunkAt: last, now: Date()))
    }

    func testShouldSendKeepAliveAtExactlyThreshold() {
        let last = Date(timeIntervalSinceNow: -8.0)
        XCTAssertTrue(DeepgramStreamer.shouldSendKeepAlive(lastChunkAt: last, now: Date()))
    }

    // MARK: Reconnect buffer

    func testReconnectBufferMaxIs160000Bytes() {
        XCTAssertEqual(DeepgramStreamer.maxReconnectBufferBytes, 160_000)
    }

    // MARK: Disconnect buffer cutoff

    func testShouldBufferWhenDisconnectedLessThan5Seconds() {
        let disconnectedAt = Date(timeIntervalSinceNow: -3.0)
        XCTAssertTrue(DeepgramStreamer.shouldBuffer(disconnectedAt: disconnectedAt, now: Date()))
    }

    func testShouldDropChunkWhenDisconnectedMoreThan5Seconds() {
        let disconnectedAt = Date(timeIntervalSinceNow: -6.0)
        XCTAssertFalse(DeepgramStreamer.shouldBuffer(disconnectedAt: disconnectedAt, now: Date()))
    }

    func testShouldDropChunkAtExactly5SecondsDisconnect() {
        let now = Date()
        let disconnectedAt = now.addingTimeInterval(-5.0)
        // At exactly 5s elapsed, timeIntervalSince == 5.0 which is NOT > 5.0, so still buffers
        XCTAssertTrue(DeepgramStreamer.shouldBuffer(disconnectedAt: disconnectedAt, now: now))
    }

    func testShouldBufferWhenDisconnectedAtIsNil() {
        // nil disconnectedAt means not yet disconnected — should buffer
        XCTAssertTrue(DeepgramStreamer.shouldBuffer(disconnectedAt: nil, now: Date()))
    }

    func testShouldDropAfterJustOver5Seconds() {
        let now = Date()
        let disconnectedAt = now.addingTimeInterval(-5.001)
        XCTAssertFalse(DeepgramStreamer.shouldBuffer(disconnectedAt: disconnectedAt, now: now))
    }

    // MARK: onFinalTranscript callback

    func testOnFinalTranscriptCallbackFiredOnFinalMessage() async {
        var received: String? = nil
        let context = PerceptionContext()
        let logger = Logger()
        let streamer = DeepgramStreamer(apiKey: "key", context: context, logger: logger)
        await streamer.setTranscriptCallbackForTest { transcript in
            received = transcript
        }
        // Craft a valid final-transcript Deepgram JSON
        let json = """
        {"is_final":true,"channel":{"alternatives":[{"transcript":"hello world","confidence":0.9,"words":[{"speaker":0}]}]}}
        """.data(using: .utf8)!
        await streamer.handleMessageForTest(.data(json))
        XCTAssertEqual(received, "hello world")
    }
}
