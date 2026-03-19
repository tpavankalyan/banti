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
}
