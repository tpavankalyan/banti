// Tests/BantiTests/ConversationBufferTests.swift
import XCTest
@testable import BantiCore

final class ConversationBufferTests: XCTestCase {

    func test_addBantiTurn_appearsInRecentTurns() async {
        let buf = ConversationBuffer()
        await buf.addBantiTurn("hello from banti")
        let turns = await buf.recentTurns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].speaker, .banti)
        XCTAssertEqual(turns[0].text, "hello from banti")
    }

    func test_addHumanTurn_appearsInRecentTurns() async {
        let buf = ConversationBuffer()
        await buf.addHumanTurn("hi banti")
        let turns = await buf.recentTurns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].speaker, .human)
    }

    func test_recentTurns_returnsInOrder() async {
        let buf = ConversationBuffer()
        await buf.addHumanTurn("first")
        await buf.addBantiTurn("second")
        await buf.addHumanTurn("third")
        let turns = await buf.recentTurns()
        XCTAssertEqual(turns.map(\.text), ["first", "second", "third"])
    }

    func test_recentTurns_respectsLimit() async {
        let buf = ConversationBuffer()
        for i in 1...15 {
            await buf.addHumanTurn("turn \(i)")
        }
        let turns = await buf.recentTurns(limit: 5)
        XCTAssertEqual(turns.count, 5)
        XCTAssertEqual(turns.first?.text, "turn 11")
        XCTAssertEqual(turns.last?.text, "turn 15")
    }

    func test_capsAt30Turns_dropsOldest() async {
        let buf = ConversationBuffer()
        for i in 1...32 {
            await buf.addHumanTurn("turn \(i)")
        }
        let turns = await buf.recentTurns(limit: 50)
        XCTAssertEqual(turns.count, 30)
        XCTAssertEqual(turns.first?.text, "turn 3")
    }

    func test_lastBantiUtterance_returnsNilWhenEmpty() async {
        let buf = ConversationBuffer()
        let last = await buf.lastBantiUtterance()
        XCTAssertNil(last)
    }

    func test_lastBantiUtterance_returnsLastBantiText() async {
        let buf = ConversationBuffer()
        await buf.addBantiTurn("first banti")
        await buf.addHumanTurn("human reply")
        await buf.addBantiTurn("second banti")
        let last = await buf.lastBantiUtterance()
        XCTAssertEqual(last, "second banti")
    }

    func test_lastBantiUtterance_returnsNilIfOnlyHumanTurns() async {
        let buf = ConversationBuffer()
        await buf.addHumanTurn("only human spoke")
        let last = await buf.lastBantiUtterance()
        XCTAssertNil(last)
    }
}
