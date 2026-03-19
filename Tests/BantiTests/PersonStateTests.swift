// Tests/BantiTests/PersonStateTests.swift
import XCTest
@testable import BantiCore

final class PersonStateTests: XCTestCase {

    func testUpdateSetsPersonField() async {
        let ctx = PerceptionContext()
        let state = PersonState(id: "p_001", name: "Alice", confidence: 0.95, updatedAt: Date())
        await ctx.update(.person(state))
        let person = await ctx.person
        XCTAssertEqual(person?.id, "p_001")
        XCTAssertEqual(person?.name, "Alice")
    }

    func testPersonFieldIsNilInitially() async {
        let ctx = PerceptionContext()
        let person = await ctx.person
        XCTAssertNil(person)
    }

    func testSnapshotIncludesPersonWhenSet() async {
        let ctx = PerceptionContext()
        let state = PersonState(id: "p_007", name: "Bob", confidence: 0.88, updatedAt: Date())
        await ctx.update(.person(state))
        let json = await ctx.snapshotJSON()
        XCTAssertTrue(json.contains("Bob"))
        XCTAssertTrue(json.contains("p_007"))
    }

    func testSnapshotExcludesPersonWhenNil() async {
        let ctx = PerceptionContext()
        let json = await ctx.snapshotJSON()
        XCTAssertFalse(json.contains("\"person\""))
    }
}
