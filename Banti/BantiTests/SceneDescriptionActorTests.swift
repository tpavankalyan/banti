import XCTest
@testable import Banti

final class SceneDescriptionActorTests: XCTestCase {

    private func makeChange(seq: UInt64 = 1, dist: Float = 0.25) -> SceneChangeEvent {
        SceneChangeEvent(
            jpeg: Data("fake-jpeg".utf8),
            changeDistance: dist,
            sequenceNumber: seq,
            captureTime: Date()
        )
    }

    func testCapabilitiesIncludesSceneDescription() {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = SceneDescriptionActor(eventHub: hub, config: config, provider: MockVisionProvider(returning: ""))
        XCTAssertTrue(actor.capabilities.contains(.sceneDescription))
    }

    func testPublishesSceneDescriptionEventOnChange() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let exp = XCTestExpectation(description: "scene description received")
        let descriptions = TestRecorder<SceneDescriptionEvent>()

        _ = await hub.subscribe(SceneDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = SceneDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "A person at a desk.")
        )
        try await actor.start()

        await hub.publish(makeChange())
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.text, "A person at a desk.")
    }

    func testChangeDistancePassedThrough() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let exp = XCTestExpectation(description: "description received")
        let descriptions = TestRecorder<SceneDescriptionEvent>()

        _ = await hub.subscribe(SceneDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = SceneDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "Scene.")
        )
        try await actor.start()

        await hub.publish(makeChange(dist: 0.42))
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        guard let dist = snapshot.first?.changeDistance else { XCTFail("No event received"); return }
        XCTAssertEqual(dist, Float(0.42), accuracy: Float(0.001))
    }

    func testVLMFailureDegradesHealth() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let callExp = XCTestExpectation(description: "VLM called")
        let provider = MockVisionProvider(throwing: VisionError("API unavailable")) {
            callExp.fulfill()
        }

        let actor = SceneDescriptionActor(eventHub: hub, config: config, provider: provider)
        try await actor.start()

        await hub.publish(makeChange())
        await fulfillment(of: [callExp], timeout: 3)

        let deadline = Date().addingTimeInterval(2)
        var healthIsDegraded = false
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            if case .degraded = await actor.health() { healthIsDegraded = true; break }
        }
        XCTAssertTrue(healthIsDegraded, "Expected degraded health after VLM failure")
    }

    func testCaptureTimeMatchesChangeEventCaptureTime() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let exp = XCTestExpectation(description: "description received")
        let descriptions = TestRecorder<SceneDescriptionEvent>()

        _ = await hub.subscribe(SceneDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = SceneDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "Test scene.")
        )
        try await actor.start()

        let changeEvent = makeChange()
        await hub.publish(changeEvent)
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        guard let first = snapshot.first else { XCTFail("No event received"); return }
        XCTAssertEqual(first.captureTime.timeIntervalSince1970,
                       changeEvent.captureTime.timeIntervalSince1970,
                       accuracy: 0.01,
                       "captureTime must come from SceneChangeEvent.captureTime, not VLM response time")
        XCTAssertGreaterThanOrEqual(first.responseTime, first.captureTime)
    }
}
