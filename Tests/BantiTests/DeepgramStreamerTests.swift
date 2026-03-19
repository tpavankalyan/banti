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
}
