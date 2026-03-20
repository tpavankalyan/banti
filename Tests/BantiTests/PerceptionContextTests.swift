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

    func testUpdateSetsVoiceEmotionField() async {
        let ctx = PerceptionContext()
        let state = VoiceEmotionState(emotions: [("Calm", 0.7)], updatedAt: Date())
        await ctx.update(.voiceEmotion(state))
        let ve = await ctx.voiceEmotion
        XCTAssertEqual(ve?.emotions.first?.label, "Calm")
    }

    func testUpdateSetsSoundField() async {
        let ctx = PerceptionContext()
        let state = SoundState(label: "music", confidence: 0.88, updatedAt: Date())
        await ctx.update(.sound(state))
        let sound = await ctx.sound
        XCTAssertEqual(sound?.label, "music")
    }

    func testSnapshotIncludesAudioFields() async {
        let ctx = PerceptionContext()
        await ctx.update(.sound(SoundState(label: "ambient", confidence: 0.95, updatedAt: Date())))
        let json = await ctx.snapshotJSON()
        XCTAssertTrue(json.contains("ambient"))
    }
}
