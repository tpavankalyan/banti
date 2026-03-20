// Tests/BantiTests/SpeakerAttributorTests.swift
import XCTest
@testable import BantiCore

final class SpeakerAttributorTests: XCTestCase {

    func test_human_whenLogNeverRegistered() async {
        let log = SelfSpeechLog()
        let result = await SpeakerAttributor().attribute(
            "hello there how are you today friend",
            arrivedAt: Date(),
            selfLog: log
        )
        XCTAssertEqual(result, .human)
    }

    func test_selfEcho_whenPlayingAndMatches() async {
        let log = SelfSpeechLog()
        await log.register(text: "let me check that for you right now")
        let result = await SpeakerAttributor().attribute(
            "let me check that for you right now",
            arrivedAt: Date(),
            selfLog: log
        )
        XCTAssertEqual(result, .selfEcho)
    }

    func test_human_whenPlayingButNoMatch() async {
        let log = SelfSpeechLog()
        await log.register(text: "banti is saying something completely different here")
        let result = await SpeakerAttributor().attribute(
            "what is the weather like tomorrow morning",
            arrivedAt: Date(),
            selfLog: log
        )
        XCTAssertEqual(result, .human)
    }

    func test_selfEcho_withinTailWindow() async {
        let log = SelfSpeechLog()
        await log.register(text: "this is what banti said a moment ago")
        await log.markPlaybackEnded()
        let result = await SpeakerAttributor().attribute(
            "this is what banti said a moment ago",
            arrivedAt: Date().addingTimeInterval(2.0),
            selfLog: log
        )
        XCTAssertEqual(result, .selfEcho)
    }

    func test_human_afterTailWindowExpired() async {
        let log = SelfSpeechLog()
        await log.register(text: "this is what banti said a moment ago")
        await log.markPlaybackEnded()
        let result = await SpeakerAttributor().attribute(
            "this is what banti said a moment ago",
            arrivedAt: Date().addingTimeInterval(6.0),
            selfLog: log
        )
        XCTAssertEqual(result, .human)
    }
}
