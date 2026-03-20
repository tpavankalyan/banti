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

    func test_capsAt60Turns_dropsOldest() async {
        let buf = ConversationBuffer(capacity: 60)
        for i in 1...62 {
            await buf.addHumanTurn("turn \(i)")
        }
        let turns = await buf.recentTurns(limit: 100)
        XCTAssertEqual(turns.count, 60)
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

    func testRingBufferWrapsAround() async {
        let buffer = ConversationBuffer(capacity: 3) // tiny capacity for test
        await buffer.addHumanTurn("turn1")
        await buffer.addHumanTurn("turn2")
        await buffer.addHumanTurn("turn3")
        await buffer.addHumanTurn("turn4") // should evict turn1

        let recent = await buffer.recentTurns(limit: 10)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.first?.text, "turn2")
        XCTAssertEqual(recent.last?.text, "turn4")
    }

    func testRecentTurnsRespectLimit() async {
        let buffer = ConversationBuffer(capacity: 60)
        for i in 1...10 { await buffer.addHumanTurn("turn\(i)") }
        let recent = await buffer.recentTurns(limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.last?.text, "turn10")
    }
}
