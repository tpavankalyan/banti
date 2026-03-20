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
        XCTAssertFalse(BrainLoop.shouldTrigger(lastSpoke: exactly10, isInterruption: false, now: now))
    }

    func testShouldTriggerTrueWhenIsInterruption() {
        // Interruption bypasses cooldown even if spoke very recently
        let justSpoke = Date().addingTimeInterval(-1)
        XCTAssertTrue(BrainLoop.shouldTrigger(lastSpoke: justSpoke, isInterruption: true))
    }

    func testShouldTriggerFalseWhenNotInterruptionAndWithinCooldown() {
        let recentlySpoke = Date().addingTimeInterval(-5)
        XCTAssertFalse(BrainLoop.shouldTrigger(lastSpoke: recentlySpoke, isInterruption: false))
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
        // inject now: to avoid wall-clock race (same pattern as testShouldTriggerFalseExactlyAt10Seconds)
        let now = Date()
        let firstSeen = now.addingTimeInterval(-30)
        XCTAssertFalse(BrainLoop.unknownPersonExceedsThreshold(firstSeen: firstSeen, now: now))
    }

    func testNameJustResolvedFalseWhenNameDisappears() {
        // name going from named to nil (person left) should not trigger "just resolved"
        XCTAssertFalse(BrainLoop.nameJustResolved(previous: "Alice", current: nil))
    }

    // MARK: - SSEEvent decoding

    func testSSEEventDecodesTypeSentence() throws {
        let json = #"{"type":"sentence","text":"Hello there!"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(SSEEvent.self, from: json)
        XCTAssertEqual(event.type, "sentence")
        XCTAssertEqual(event.text, "Hello there!")
    }

    func testSSEEventDecodesDone() throws {
        let json = #"{"type":"done"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(SSEEvent.self, from: json)
        XCTAssertEqual(event.type, "done")
        XCTAssertNil(event.text)
    }

    func testSSEEventDecodesSilent() throws {
        let json = #"{"type":"silent"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(SSEEvent.self, from: json)
        XCTAssertEqual(event.type, "silent")
    }

    // MARK: - Interruption detection

    func testIsInterruptionCandidateTrueForMultiWord() {
        XCTAssertTrue(BrainLoop.isInterruptionCandidate("hello there"))
    }

    func testIsInterruptionCandidateFalseForSingleWord() {
        XCTAssertFalse(BrainLoop.isInterruptionCandidate("hello"))
    }

    func testIsInterruptionCandidateFalseForEmptyString() {
        XCTAssertFalse(BrainLoop.isInterruptionCandidate(""))
    }

    func testIsInterruptionCandidateTrueForThreeWords() {
        XCTAssertTrue(BrainLoop.isInterruptionCandidate("wait hold on"))
    }

    // MARK: - BrainStreamBody

    func testBrainStreamBodyEncodesConversationHistory() throws {
        let turn = ConversationTurnDTO(speaker: "human", text: "hello", timestamp: 1000.0)
        let body = BrainStreamBody(
            track: "reflex",
            ambient_context: "{}",
            conversation_history: [turn],
            last_banti_utterance: "hi there",
            last_spoke_seconds_ago: 5.0,
            is_interruption: false,
            current_speech: nil
        )
        let data = try JSONEncoder().encode(body)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["ambient_context"] as? String, "{}")
        let history = json["conversation_history"] as? [[String: Any]]
        XCTAssertEqual(history?.count, 1)
        XCTAssertEqual(history?.first?["speaker"] as? String, "human")
        XCTAssertEqual(history?.first?["text"] as? String, "hello")
        XCTAssertEqual(json["last_banti_utterance"] as? String, "hi there")
        XCTAssertEqual(json["is_interruption"] as? Bool, false)
    }

    func testBrainStreamBodyEncodesInterruptionTrue() throws {
        let body = BrainStreamBody(
            track: "reasoning",
            ambient_context: "{}",
            conversation_history: [],
            last_banti_utterance: nil,
            last_spoke_seconds_ago: 2.0,
            is_interruption: true,
            current_speech: "I was saying this"
        )
        let data = try JSONEncoder().encode(body)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["is_interruption"] as? Bool, true)
        XCTAssertEqual(json["current_speech"] as? String, "I was saying this")
    }
}
