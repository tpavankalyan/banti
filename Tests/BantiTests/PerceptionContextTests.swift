// Tests/BantiTests/PerceptionContextTests.swift
import XCTest
@testable import BantiCore

final class PerceptionContextTests: XCTestCase {

    func testUpdateSetsCorrectField() async {
        let ctx = PerceptionContext()
        let now = Date()
        await ctx.update(.activity(ActivityState(description: "typing", updatedAt: now)))
        let activity = await ctx.activity
        XCTAssertEqual(activity?.description, "typing")
    }

    func testSnapshotContainsSetFields() async throws {
        let ctx = PerceptionContext()
        let now = Date()
        await ctx.update(.activity(ActivityState(description: "reading", updatedAt: now)))
        await ctx.update(.emotion(EmotionState(emotions: [("calm", 0.8)], updatedAt: now)))
        let json = await ctx.snapshotJSON()
        XCTAssertTrue(json.contains("reading"))
        XCTAssertTrue(json.contains("calm"))
    }

    func testSnapshotIsEmptyWhenNoStateSet() async throws {
        let ctx = PerceptionContext()
        let json = await ctx.snapshotJSON()
        XCTAssertEqual(json, "{}")
    }
}
