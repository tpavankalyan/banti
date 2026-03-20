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
        XCTAssertEqual(event.id, decoded.id)
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

    func testAllPayloadCasesRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        func roundTrip(_ event: BantiEvent) throws -> BantiEvent {
            try decoder.decode(BantiEvent.self, from: try encoder.encode(event))
        }

        // screenUpdate
        let screenEvent = BantiEvent(source: "s", topic: "sensor.screen", surprise: 0,
            payload: .screenUpdate(ScreenPayload(ocrLines: ["x"], interpretation: "y")))
        let decodedScreen = try roundTrip(screenEvent)
        guard case .screenUpdate(let sp) = decodedScreen.payload else { return XCTFail("screenUpdate") }
        XCTAssertEqual(sp.interpretation, "y")

        // emotionUpdate
        let emotionEvent = BantiEvent(source: "s", topic: "sensor.audio", surprise: 0,
            payload: .emotionUpdate(EmotionPayload(emotions: [.init(label: "joy", score: 0.9)], source: "hume_voice")))
        let decodedEmotion = try roundTrip(emotionEvent)
        guard case .emotionUpdate(let ep) = decodedEmotion.payload else { return XCTFail("emotionUpdate") }
        XCTAssertEqual(ep.emotions.first?.label, "joy")

        // soundUpdate
        let soundEvent = BantiEvent(source: "s", topic: "sensor.audio", surprise: 0,
            payload: .soundUpdate(SoundPayload(label: "bark", confidence: 0.7)))
        let decodedSound = try roundTrip(soundEvent)
        guard case .soundUpdate(let snd) = decodedSound.payload else { return XCTFail("soundUpdate") }
        XCTAssertEqual(snd.label, "bark")

        // episodeBound
        let episode = EpisodePayload(text: "hi", participants: ["p1"], emotionalTone: "neutral")
        let episodeEvent = BantiEvent(source: "s", topic: "episode.bound", surprise: 0,
            payload: .episodeBound(episode))
        let decodedEpisode = try roundTrip(episodeEvent)
        guard case .episodeBound(let epl) = decodedEpisode.payload else { return XCTFail("episodeBound") }
        XCTAssertEqual(epl.text, "hi")

        // brainRoute
        let routeEvent = BantiEvent(source: "s", topic: "brain.route", surprise: 0,
            payload: .brainRoute(BrainRoutePayload(tracks: ["reflex"], reason: "fast", episode: episode)))
        let decodedRoute = try roundTrip(routeEvent)
        guard case .brainRoute(let rp) = decodedRoute.payload else { return XCTFail("brainRoute") }
        XCTAssertEqual(rp.tracks, ["reflex"])

        // brainResponse
        let respEvent = BantiEvent(source: "s", topic: "brain.response", surprise: 0,
            payload: .brainResponse(BrainResponsePayload(track: "reflex", text: "ok", activatedTracks: ["reflex"])))
        let decodedResp = try roundTrip(respEvent)
        guard case .brainResponse(let rsp) = decodedResp.payload else { return XCTFail("brainResponse") }
        XCTAssertEqual(rsp.text, "ok")

        // speechPlan
        let planEvent = BantiEvent(source: "s", topic: "motor.speech_plan", surprise: 0,
            payload: .speechPlan(SpeechPlanPayload(sentences: ["hello"])))
        let decodedPlan = try roundTrip(planEvent)
        guard case .speechPlan(let pp) = decodedPlan.payload else { return XCTFail("speechPlan") }
        XCTAssertEqual(pp.sentences, ["hello"])

        // memoryRetrieved
        let memEvent = BantiEvent(source: "s", topic: "memory.retrieved", surprise: 0,
            payload: .memoryRetrieved(MemoryRetrievedPayload(personID: "p1", personName: "Pavan", facts: ["likes coffee"])))
        let decodedMem = try roundTrip(memEvent)
        guard case .memoryRetrieved(let mp) = decodedMem.payload else { return XCTFail("memoryRetrieved") }
        XCTAssertEqual(mp.facts, ["likes coffee"])

        // memorySaved
        let savedEvent = BantiEvent(source: "s", topic: "memory.saved", surprise: 0,
            payload: .memorySaved(MemorySavedPayload(episodeID: UUID(), stored: true)))
        let decodedSaved = try roundTrip(savedEvent)
        guard case .memorySaved(let msp) = decodedSaved.payload else { return XCTFail("memorySaved") }
        XCTAssertTrue(msp.stored)
    }
}
