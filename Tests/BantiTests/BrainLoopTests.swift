// Tests/BantiTests/BrainLoopTests.swift
import XCTest
@testable import BantiCore

final class BrainLoopTests: XCTestCase {

    // MARK: - Cooldown

    func testShouldTriggerTrueWhenNeverSpoke() {
        XCTAssertTrue(BrainLoop.shouldTrigger(lastSpoke: nil))
    }

    func testShouldTriggerFalseWithin10Seconds() {
        let recentlySpoke = Date().addingTimeInterval(-5)
        XCTAssertFalse(BrainLoop.shouldTrigger(lastSpoke: recentlySpoke))
    }

    func testShouldTriggerTrueAfter10Seconds() {
        let longAgo = Date().addingTimeInterval(-11)
        XCTAssertTrue(BrainLoop.shouldTrigger(lastSpoke: longAgo))
    }

    func testShouldTriggerFalseExactlyAt10Seconds() {
        // At exactly 10s it should NOT trigger yet (strictly greater than)
        // Inject same `now` to avoid timing gap between Date() calls
        let now = Date()
        let exactly10 = now.addingTimeInterval(-10)
        XCTAssertFalse(BrainLoop.shouldTrigger(lastSpoke: exactly10, now: now))
    }

    // MARK: - Transcript buffer

    func testAppendTranscriptIgnoresNonFinal() {
        var transcripts: [String] = []
        BrainLoop.appendTranscript(&transcripts, new: "hello", isFinal: false)
        XCTAssertTrue(transcripts.isEmpty)
    }

    func testAppendTranscriptAddsFinalTranscript() {
        var transcripts: [String] = []
        BrainLoop.appendTranscript(&transcripts, new: "hello", isFinal: true)
        XCTAssertEqual(transcripts, ["hello"])
    }

    func testAppendTranscriptIgnoresDuplicate() {
        var transcripts = ["hello"]
        BrainLoop.appendTranscript(&transcripts, new: "hello", isFinal: true)
        XCTAssertEqual(transcripts.count, 1)
    }

    func testAppendTranscriptIgnoresNil() {
        var transcripts: [String] = []
        BrainLoop.appendTranscript(&transcripts, new: nil, isFinal: true)
        XCTAssertTrue(transcripts.isEmpty)
    }

    func testTranscriptBufferCapsAt5() {
        var transcripts: [String] = []
        for i in 1...7 {
            BrainLoop.appendTranscript(&transcripts, new: "line \(i)", isFinal: true)
        }
        XCTAssertEqual(transcripts.count, 5)
        XCTAssertEqual(transcripts.first, "line 3")
        XCTAssertEqual(transcripts.last, "line 7")
    }

    // MARK: - ProactiveDecision parsing

    func testDecodesSpeakDecision() throws {
        let json = #"{"action":"speak","text":"Hello!","reason":"idle"}"#.data(using: .utf8)!
        let decision = try JSONDecoder().decode(ProactiveDecision.self, from: json)
        XCTAssertEqual(decision.action, "speak")
        XCTAssertEqual(decision.text, "Hello!")
    }

    func testDecodesSilentDecision() throws {
        let json = #"{"action":"silent","text":null,"reason":"busy"}"#.data(using: .utf8)!
        let decision = try JSONDecoder().decode(ProactiveDecision.self, from: json)
        XCTAssertEqual(decision.action, "silent")
        XCTAssertNil(decision.text)
    }

    // MARK: - Event trigger detection

    func testIsEmotionSpikeTrueWhenValenceDropsBelow0Point3() {
        // Simulate a strong negative emotion state (valence as a proxy: sadness/fear score > 0.7)
        XCTAssertTrue(BrainLoop.isEmotionSpike(topScore: 0.8))
    }

    func testIsEmotionSpikeFalseForMildEmotion() {
        XCTAssertFalse(BrainLoop.isEmotionSpike(topScore: 0.4))
    }

    func testUnknownPersonExceedsThresholdAfter30Seconds() {
        let firstSeen = Date().addingTimeInterval(-31)
        XCTAssertTrue(BrainLoop.unknownPersonExceedsThreshold(firstSeen: firstSeen))
    }

    func testUnknownPersonDoesNotExceedThresholdBefore30Seconds() {
        let firstSeen = Date().addingTimeInterval(-20)
        XCTAssertFalse(BrainLoop.unknownPersonExceedsThreshold(firstSeen: firstSeen))
    }

    func testNameJustResolvedDetectsTransitionFromNilToName() {
        XCTAssertTrue(BrainLoop.nameJustResolved(previous: nil, current: "Alice"))
    }

    func testNameJustResolvedFalseWhenAlreadyKnown() {
        XCTAssertFalse(BrainLoop.nameJustResolved(previous: "Alice", current: "Alice"))
    }

    func testNameJustResolvedFalseWhenStillUnknown() {
        XCTAssertFalse(BrainLoop.nameJustResolved(previous: nil, current: nil))
    }

    // MARK: - lastSpoke seconds calculation

    func testSecondsSinceLastSpokeIsLargeWhenNeverSpoke() {
        let secs = BrainLoop.secondsSince(nil)
        XCTAssertGreaterThan(secs, 9998)
    }

    func testSecondsSinceLastSpokeIsAccurate() {
        let t = Date().addingTimeInterval(-30)
        let secs = BrainLoop.secondsSince(t)
        XCTAssertGreaterThanOrEqual(secs, 29)
        XCTAssertLessThan(secs, 32)
    }

    // MARK: - Additional boundary tests

    func testIsEmotionSpikeAtExactThreshold() {
        // threshold is >= 0.7, so exactly 0.7 should trigger
        XCTAssertTrue(BrainLoop.isEmotionSpike(topScore: 0.7))
    }

    func testUnknownPersonDoesNotExceedThresholdAtExactly30Seconds() {
        // threshold is > 30s, so exactly 30s should NOT trigger
        let firstSeen = Date().addingTimeInterval(-30)
        XCTAssertFalse(BrainLoop.unknownPersonExceedsThreshold(firstSeen: firstSeen))
    }

    func testNameJustResolvedFalseWhenNameDisappears() {
        // name going from named to nil (person left) should not trigger "just resolved"
        XCTAssertFalse(BrainLoop.nameJustResolved(previous: "Alice", current: nil))
    }
}
