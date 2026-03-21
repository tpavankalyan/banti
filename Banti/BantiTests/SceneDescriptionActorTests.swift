import XCTest
@testable import Banti

final class SceneDescriptionActorTests: XCTestCase {

    private func makeFrame(seq: UInt64 = 1) -> CameraFrameEvent {
        CameraFrameEvent(
            jpeg: Data("fake-jpeg".utf8),
            sequenceNumber: seq,
            frameWidth: 640,
            frameHeight: 480
        )
    }

    func testCapabilitiesIncludesSceneDescription() {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = SceneDescriptionActor(eventHub: hub, config: config, provider: MockVisionProvider(returning: ""))
        XCTAssertTrue(actor.capabilities.contains(.sceneDescription))
    }

    func testPublishesSceneDescriptionEventOnFrame() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCENE_DESCRIPTION_INTERVAL_S=0")
        let exp = XCTestExpectation(description: "scene description received")
        let descriptions = TestRecorder<SceneDescriptionEvent>()

        _ = await hub.subscribe(SceneDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = SceneDescriptionActor(eventHub: hub, config: config, provider: MockVisionProvider(returning: "A person at a desk."))
        try await actor.start()

        await hub.publish(makeFrame())
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.text, "A person at a desk.")
    }

    func testThrottlesWithinInterval() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCENE_DESCRIPTION_INTERVAL_S=10")
        let firstExp = XCTestExpectation(description: "first scene published")
        let descriptions = TestRecorder<SceneDescriptionEvent>()

        _ = await hub.subscribe(SceneDescriptionEvent.self) { event in
            await descriptions.append(event)
            firstExp.fulfill()
        }

        let actor = SceneDescriptionActor(
            eventHub: hub,
            config: config,
            provider: MockVisionProvider(returning: "Scene.")
        )
        try await actor.start()

        await hub.publish(makeFrame(seq: 1))
        await fulfillment(of: [firstExp], timeout: 3)

        await hub.publish(makeFrame(seq: 2))
        try await Task.sleep(for: .milliseconds(200))

        let snapshot = await descriptions.snapshot()
        XCTAssertEqual(snapshot.count, 1, "Second frame within 10s interval should be throttled")
    }

    func testVLMFailureDegradesHealth() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCENE_DESCRIPTION_INTERVAL_S=0")

        let callExp = XCTestExpectation(description: "VLM called")
        let provider = MockVisionProvider(throwing: VisionError("API unavailable")) {
            callExp.fulfill()
        }

        let actor = SceneDescriptionActor(eventHub: hub, config: config, provider: provider)
        try await actor.start()

        await hub.publish(makeFrame())

        await fulfillment(of: [callExp], timeout: 3)

        // Poll until health degrades or timeout expires.
        let deadline = Date().addingTimeInterval(2)
        var healthIsDegraded = false
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            if case .degraded = await actor.health() {
                healthIsDegraded = true
                break
            }
        }
        XCTAssertTrue(healthIsDegraded, "Expected degraded health after VLM failure")
    }

    func testCaptureTimeMatchesFrameTimestamp() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCENE_DESCRIPTION_INTERVAL_S=0")
        let exp = XCTestExpectation(description: "description received")
        let descriptions = TestRecorder<SceneDescriptionEvent>()

        _ = await hub.subscribe(SceneDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = SceneDescriptionActor(
            eventHub: hub,
            config: config,
            provider: MockVisionProvider(returning: "Test scene.")
        )
        try await actor.start()

        let beforePublish = Date()
        await hub.publish(makeFrame())

        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        guard let first = snapshot.first else { XCTFail("No event received"); return }

        XCTAssertLessThan(abs(first.captureTime.timeIntervalSince(beforePublish)), 1.0,
                          "captureTime should match frame.timestamp, not VLM response time")
        XCTAssertGreaterThanOrEqual(first.responseTime, first.captureTime)
    }
}
