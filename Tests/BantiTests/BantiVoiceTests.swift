// Tests/BantiTests/BantiVoiceTests.swift
import XCTest
import AVFoundation
@testable import BantiCore

final class BantiVoiceTests: XCTestCase {

    // Shared test infrastructure
    private func makeBantiVoice() -> (BantiVoice, SelfSpeechLog, ConversationBuffer) {
        let engine = AVAudioEngine()
        let log = SelfSpeechLog()
        let buf = ConversationBuffer()
        let speaker = CartesiaSpeaker(engine: engine, logger: Logger())
        let voice = BantiVoice(
            cartesiaSpeaker: speaker,
            selfSpeechLog: log,
            conversationBuffer: buf,
            logger: Logger()
        )
        return (voice, log, buf)
    }

    func test_say_registersInSelfSpeechLog() async {
        let (voice, log, _) = makeBantiVoice()
        // We only test the side-effects on SelfSpeechLog, not actual TTS (no API key in tests)
        // After say(), isCurrentlyPlaying should be true (register was called)
        // Note: streamSpeak will fail silently (no API key) but register() runs first
        await voice.say("hello friend this is a test", track: .reflex)
        let playing = await log.isCurrentlyPlaying
        // isCurrentlyPlaying was set true by register(); may be true or false depending on
        // whether streamSpeak returned (no TTS key = immediate return).
        // What we can assert: attribution of the exact text should be selfEcho while gate is active.
        // Re-register manually to check the log accepted it.
        let echo = await log.isSelfEcho(transcript: "hello friend this is a test", arrivedAt: Date())
        // gate active (isCurrentlyPlaying set by register) + fuzzy match → true
        XCTAssertTrue(echo)
        _ = playing  // suppress unused warning
    }

    func test_say_writesBantiTurnToConversationBuffer() async {
        let (voice, _, buf) = makeBantiVoice()
        await voice.say("testing the buffer here", track: .reflex)
        let turns = await buf.recentTurns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].speaker, .banti)
        XCTAssertEqual(turns[0].text, "testing the buffer here")
    }

    func test_markPlaybackEnded_clearsIsCurrentlyPlaying() async {
        let (voice, log, _) = makeBantiVoice()
        await voice.say("some test phrase for the log", track: .reflex)
        await voice.markPlaybackEnded()
        let playing = await log.isCurrentlyPlaying
        XCTAssertFalse(playing)
    }

    func test_attributeTranscript_selfEcho_whenJustSpoke() async {
        let (voice, _, _) = makeBantiVoice()
        await voice.say("let me look into that for you now", track: .reflex)
        let result = await voice.attributeTranscript(
            "let me look into that for you now",
            arrivedAt: Date()
        )
        XCTAssertEqual(result, .selfEcho)
    }

    func test_attributeTranscript_human_forUnrelatedText() async {
        let (voice, _, _) = makeBantiVoice()
        // Nothing registered — all transcripts are human
        let result = await voice.attributeTranscript(
            "what is the weather like tomorrow morning",
            arrivedAt: Date()
        )
        XCTAssertEqual(result, .human)
    }

    func test_suppressSelfEcho_delegatesToLog() async {
        let (voice, log, _) = makeBantiVoice()
        await log.register(text: "this is a test phrase with sufficient words here")
        let cleaned = await voice.suppressSelfEcho(in: "this is a test phrase with sufficient words here")
        XCTAssertTrue(cleaned.count < 20)
    }
}
