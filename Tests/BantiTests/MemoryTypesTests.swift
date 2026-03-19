// Tests/BantiTests/MemoryTypesTests.swift
import XCTest
@testable import BantiCore

final class MemoryTypesTests: XCTestCase {

    func testSpeechStateAcceptsResolvedName() {
        let state = SpeechState(
            transcript: "hello",
            speakerID: 0,
            isFinal: true,
            confidence: 0.9,
            resolvedName: "Alice",
            updatedAt: Date()
        )
        XCTAssertEqual(state.resolvedName, "Alice")
    }

    func testSpeechStateResolvedNameDefaultsToNil() {
        let state = SpeechState(
            transcript: "hello",
            speakerID: nil,
            isFinal: false,
            confidence: 0.5,
            resolvedName: nil,
            updatedAt: Date()
        )
        XCTAssertNil(state.resolvedName)
    }

    func testPersonStateIsCreatable() {
        let state = PersonState(id: "p_001", name: "Bob", confidence: 0.92, updatedAt: Date())
        XCTAssertEqual(state.id, "p_001")
        XCTAssertEqual(state.name, "Bob")
        XCTAssertEqual(state.confidence, 0.92, accuracy: 0.001)
    }

    func testPersonStateUnknownHasNilName() {
        let state = PersonState(id: "p_099", name: nil, confidence: 0.0, updatedAt: Date())
        XCTAssertNil(state.name)
    }

    func testMemoryActionIntroduceYourself() {
        let action = MemoryAction.introduceYourself(personID: "p_042")
        if case .introduceYourself(let id) = action {
            XCTAssertEqual(id, "p_042")
        } else {
            XCTFail("Wrong case")
        }
    }

    func testMemoryResponseHasAnswer() {
        let response = MemoryResponse(answer: "Alice is a designer", sources: ["mem0"])
        XCTAssertEqual(response.answer, "Alice is a designer")
        XCTAssertEqual(response.sources, ["mem0"])
    }

    func testProactiveDecisionDecodesSpeakWithText() throws {
        let json = """
        {"action":"speak","text":"Hello there!","reason":"user looks idle"}
        """.data(using: .utf8)!
        let decision = try JSONDecoder().decode(ProactiveDecision.self, from: json)
        XCTAssertEqual(decision.action, "speak")
        XCTAssertEqual(decision.text, "Hello there!")
        XCTAssertEqual(decision.reason, "user looks idle")
    }

    func testProactiveDecisionDecodesSilentWithNilText() throws {
        let json = """
        {"action":"silent","text":null,"reason":"focused"}
        """.data(using: .utf8)!
        let decision = try JSONDecoder().decode(ProactiveDecision.self, from: json)
        XCTAssertEqual(decision.action, "silent")
        XCTAssertNil(decision.text)
    }

    func testProactiveDecisionDecodesSilentWithMissingText() throws {
        let json = """
        {"action":"silent","reason":"nothing to add"}
        """.data(using: .utf8)!
        let decision = try JSONDecoder().decode(ProactiveDecision.self, from: json)
        XCTAssertNil(decision.text)
    }
}
