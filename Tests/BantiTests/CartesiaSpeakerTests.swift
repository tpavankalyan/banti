// Tests/BantiTests/CartesiaSpeakerTests.swift
import XCTest
import AVFoundation
@testable import BantiCore

final class CartesiaSpeakerTests: XCTestCase {

    func testIsAvailableFalseWhenNoAPIKey() async {
        let speaker = CartesiaSpeaker(engine: AVAudioEngine(), logger: Logger(), apiKey: nil, voiceID: "test-voice")
        let available = await speaker.isAvailable
        XCTAssertFalse(available)
    }

    func testIsAvailableTrueWhenAPIKeyPresent() async {
        let speaker = CartesiaSpeaker(engine: AVAudioEngine(), logger: Logger(), apiKey: "test-key", voiceID: "test-voice")
        let available = await speaker.isAvailable
        XCTAssertTrue(available)
    }

    func testSpeakDoesNotCrashWhenUnavailable() async {
        let speaker = CartesiaSpeaker(engine: AVAudioEngine(), logger: Logger(), apiKey: nil, voiceID: "test-voice")
        // Should be a no-op — just verify no crash
        await speaker.speak("hello")
    }

    func testMakeBufferReturnsNilForEmptyData() {
        let result = CartesiaSpeaker.makeBuffer(Data(), sampleRate: 22050)
        XCTAssertNil(result)
    }

    func testMakeBufferReturnsPCMBufferForValidData() {
        // 100 frames of Int16 mono PCM = 200 bytes
        let bytes = Data(repeating: 0, count: 200)
        let buffer = CartesiaSpeaker.makeBuffer(bytes, sampleRate: 22050)
        XCTAssertNotNil(buffer)
        XCTAssertEqual(buffer?.frameLength, 100)
    }

    func testPendingTextIsReplacedWhenSpeakCalledWhileBusy() async {
        let speaker = CartesiaSpeaker(engine: AVAudioEngine(), logger: Logger(), apiKey: "key", voiceID: "voice")
        // Simulate busy state and queue replacement
        await speaker.setIsSpeakingForTest(true)
        await speaker.speak("first message")
        await speaker.speak("second message")  // should replace first
        let pending = await speaker.pendingTextForTest
        XCTAssertEqual(pending, "second message")
    }

    func testStreamSpeakIsNoOpWhenUnavailable() async {
        let speaker = CartesiaSpeaker(engine: AVAudioEngine(), logger: Logger(), apiKey: nil, voiceID: "test")
        // Must not crash
        await speaker.streamSpeak("hello there friend", track: .reflex)
    }

    func testCancelTrackReflexClearsIsSpeaking() async {
        let speaker = CartesiaSpeaker(engine: AVAudioEngine(), logger: Logger(), apiKey: "key", voiceID: "voice")
        await speaker.setIsSpeakingReflexForTest(true)
        await speaker.cancelTrack(.reflex)
        let isSpeaking = await speaker.isSpeakingReflexForTest
        XCTAssertFalse(isSpeaking)
    }

    func testCancelTrackReasoningClearsPendingBuffers() async {
        let speaker = CartesiaSpeaker(engine: AVAudioEngine(), logger: Logger(), apiKey: "key", voiceID: "voice")
        await speaker.addPendingReasoningBufferForTest()
        await speaker.cancelTrack(.reasoning)
        let count = await speaker.pendingReasoningBufferCountForTest
        XCTAssertEqual(count, 0)
    }

    func testFinishCurrentSentenceReturnsImmediatelyWhenNotSpeaking() async {
        let speaker = CartesiaSpeaker(engine: AVAudioEngine(), logger: Logger(), apiKey: "key", voiceID: "voice")
        let start = Date()
        await speaker.finishCurrentSentence()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testInitWithSharedEngineDoesNotCrash() async {
        let engine = AVAudioEngine()
        // Should not crash — attach+connect happen in init before engine.start()
        let speaker = CartesiaSpeaker(engine: engine, logger: Logger(), apiKey: nil, voiceID: "test")
        let available = await speaker.isAvailable
        XCTAssertFalse(available)  // nil apiKey
    }
}
