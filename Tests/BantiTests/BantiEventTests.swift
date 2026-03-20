// Tests/BantiTests/BantiEventTests.swift
import XCTest
@testable import BantiCore

final class BantiEventTests: XCTestCase {

    func testSpeechPayloadRoundTrip() throws {
        let payload = SpeechPayload(transcript: "hello world", speakerID: "p1")
        let event = BantiEvent(source: "audio_cortex", topic: "sensor.audio",
                               surprise: 0.8, payload: .speechDetected(payload))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BantiEvent.self, from: data)
        guard case .speechDetected(let p) = decoded.payload else {
            return XCTFail("wrong payload case")
        }
        XCTAssertEqual(p.transcript, "hello world")
        XCTAssertEqual(p.speakerID, "p1")
        XCTAssertEqual(decoded.source, "audio_cortex")
        XCTAssertEqual(decoded.topic, "sensor.audio")
    }

    func testFacePayloadRoundTrip() throws {
        let rect = CodableCGRect(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let payload = FacePayload(boundingBox: rect, personID: "abc", personName: "Alice", confidence: 0.95)
        let event = BantiEvent(source: "visual_cortex", topic: "sensor.visual",
                               surprise: 0.5, payload: .faceUpdate(payload))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BantiEvent.self, from: data)
        guard case .faceUpdate(let p) = decoded.payload else {
            return XCTFail("wrong payload case")
        }
        XCTAssertEqual(p.personName, "Alice")
        XCTAssertEqual(p.confidence, 0.95, accuracy: 0.001)
    }

    func testVoiceSpeakingPayloadRoundTrip() throws {
        let payload = VoiceSpeakingPayload(speaking: true, estimatedDurationMs: 2500,
                                           tailWindowMs: 5000, text: "hey there")
        let event = BantiEvent(source: "banti_voice", topic: "motor.voice",
                               surprise: 0.0, payload: .voiceSpeaking(payload))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BantiEvent.self, from: data)
        guard case .voiceSpeaking(let p) = decoded.payload else {
            return XCTFail("wrong payload case")
        }
        XCTAssertTrue(p.speaking)
        XCTAssertEqual(p.estimatedDurationMs, 2500)
        XCTAssertEqual(p.text, "hey there")
    }

    func testTimestampIsPopulated() {
        let event = BantiEvent(source: "x", topic: "y", surprise: 0, payload: .speechDetected(SpeechPayload(transcript: "t", speakerID: nil)))
        XCTAssertGreaterThan(event.timestampNs, 0)
    }
}
