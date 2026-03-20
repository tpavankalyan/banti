// Tests/BantiTests/ContextAggregatorTests.swift
import XCTest
@testable import BantiCore

final class ContextAggregatorTests: XCTestCase {

    func testSnapshotEmptyByDefault() async {
        let agg = ContextAggregator()
        let snap = await agg.snapshotJSON()
        XCTAssertEqual(snap, "{}")
    }

    func testAggregatesScreenEvent() async {
        let bus = EventBus()
        let agg = ContextAggregator()
        await agg.start(bus: bus)

        let screen = ScreenPayload(ocrLines: ["hello"], interpretation: "user is reading")
        await bus.publish(
            BantiEvent(source: "screen_cortex", topic: "sensor.screen", surprise: 0.5,
                       payload: .screenUpdate(screen)),
            topic: "sensor.screen"
        )
        try? await Task.sleep(nanoseconds: 50_000_000) // let Task dispatch complete

        let snap = await agg.snapshotJSON()
        XCTAssertTrue(snap.contains("user is reading"), "expected screen interpretation in snapshot, got: \(snap)")
    }

    func testAggregatesSpeechEvent() async {
        let bus = EventBus()
        let agg = ContextAggregator()
        await agg.start(bus: bus)

        let speech = SpeechPayload(transcript: "let's get to work", speakerID: "p1")
        await bus.publish(
            BantiEvent(source: "audio_cortex", topic: "sensor.audio", surprise: 0.9,
                       payload: .speechDetected(speech)),
            topic: "sensor.audio"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        let snap = await agg.snapshotJSON()
        XCTAssertTrue(snap.contains("let's get to work"), "expected transcript in snapshot")
    }

    func testSnapshotJSONIsValidJSON() async {
        let bus = EventBus()
        let agg = ContextAggregator()
        await agg.start(bus: bus)

        let face = FacePayload(
            boundingBox: CodableCGRect(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
            personID: "p1", personName: "Pavan", confidence: 0.9
        )
        await bus.publish(
            BantiEvent(source: "visual_cortex", topic: "sensor.visual", surprise: 0.6,
                       payload: .faceUpdate(face)),
            topic: "sensor.visual"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        let snap = await agg.snapshotJSON()
        let data = snap.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }
}
