// Tests/BantiTests/CartesiaSpeakerTests.swift
import XCTest
import AVFoundation
@testable import BantiCore

final class CartesiaSpeakerTests: XCTestCase {

    func testIsAvailableFalseWhenNoAPIKey() async {
        let speaker = CartesiaSpeaker(logger: Logger(), apiKey: nil, voiceID: "test-voice")
        let available = await speaker.isAvailable
        XCTAssertFalse(available)
    }

    func testIsAvailableTrueWhenAPIKeyPresent() async {
        let speaker = CartesiaSpeaker(logger: Logger(), apiKey: "test-key", voiceID: "test-voice")
        let available = await speaker.isAvailable
        XCTAssertTrue(available)
    }

    func testSpeakDoesNotCrashWhenUnavailable() async {
        let speaker = CartesiaSpeaker(logger: Logger(), apiKey: nil, voiceID: "test-voice")
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
        let speaker = CartesiaSpeaker(logger: Logger(), apiKey: "key", voiceID: "voice")
        // Simulate busy state and queue replacement
        await speaker.setIsSpeakingForTest(true)
        await speaker.speak("first message")
        await speaker.speak("second message")  // should replace first
        let pending = await speaker.pendingTextForTest
        XCTAssertEqual(pending, "second message")
    }
}
