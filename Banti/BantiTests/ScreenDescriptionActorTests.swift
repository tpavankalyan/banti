import XCTest
@testable import Banti

final class ScreenDescriptionActorTests: XCTestCase {

    private func makeChange(seq: UInt64 = 1, dist: Float? = 0.08) -> ScreenChangeEvent {
        ScreenChangeEvent(
            jpeg: Data("fake-jpeg".utf8),
            changeDistance: dist,
            sequenceNumber: seq,
            captureTime: Date()
        )
    }

    func testCapabilityIncludesScreenDescription() {
        let actor = ScreenDescriptionActor(
            eventHub: EventHubActor(),
            config: ConfigActor(content: ""),
            provider: MockVisionProvider(returning: "")
        )
        XCTAssertTrue(actor.capabilities.contains(.screenDescription))
    }

    func testPublishesScreenDescriptionEventOnChange() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let exp = XCTestExpectation(description: "screen description received")
        let descriptions = TestRecorder<ScreenDescriptionEvent>()

        _ = await hub.subscribe(ScreenDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = ScreenDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "Xcode with Swift code visible.")
        )
        try await actor.start()

        await hub.publish(makeChange())
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.text, "Xcode with Swift code visible.")
    }

    func testChangeDistancePassedThrough() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let exp = XCTestExpectation(description: "description received")
        let descriptions = TestRecorder<ScreenDescriptionEvent>()

        _ = await hub.subscribe(ScreenDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = ScreenDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "Screen.")
        )
        try await actor.start()

        await hub.publish(makeChange(dist: 0.12))
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        guard let dist = snapshot.first?.changeDistance else { XCTFail("No event received"); return }
        XCTAssertEqual(dist, Float(0.12), accuracy: Float(0.001))
    }

    func testNilChangeDistancePassedThrough() async throws {
        // First-frame ScreenChangeEvent has nil changeDistance
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let exp = XCTestExpectation(description: "description received")
        let descriptions = TestRecorder<ScreenDescriptionEvent>()

        _ = await hub.subscribe(ScreenDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = ScreenDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "Screen.")
        )
        try await actor.start()

        await hub.publish(makeChange(dist: nil))
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        XCTAssertNil(snapshot.first?.changeDistance, "nil changeDistance must be propagated")
    }

    func testNoTimeThrottling() async throws {
        // Back-to-back ScreenChangeEvents must both trigger VLM calls — no residual throttle
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        var callCount = 0
        let secondExp = XCTestExpectation(description: "second description received")
        let descriptions = TestRecorder<ScreenDescriptionEvent>()

        _ = await hub.subscribe(ScreenDescriptionEvent.self) { event in
            await descriptions.append(event)
            callCount += 1
            if callCount >= 2 { secondExp.fulfill() }
        }

        let actor = ScreenDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "Screen.")
        )
        try await actor.start()

        await hub.publish(makeChange(seq: 1))
        await hub.publish(makeChange(seq: 2))
        await fulfillment(of: [secondExp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        XCTAssertEqual(snapshot.count, 2, "Both back-to-back events must produce descriptions (no time throttle)")
    }

    func testVLMFailureDegradesHealth() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let callExp = XCTestExpectation(description: "VLM called")
        let provider = MockVisionProvider(throwing: VisionError("API unavailable")) {
            callExp.fulfill()
        }

        let actor = ScreenDescriptionActor(eventHub: hub, config: config, provider: provider)
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
        let descriptions = TestRecorder<ScreenDescriptionEvent>()

        _ = await hub.subscribe(ScreenDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = ScreenDescriptionActor(
            eventHub: hub, config: config,
            provider: MockVisionProvider(returning: "Test screen.")
        )
        try await actor.start()

        let changeEvent = makeChange()
        await hub.publish(changeEvent)
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        guard let first = snapshot.first else { XCTFail("No event"); return }
        XCTAssertEqual(first.captureTime.timeIntervalSince1970,
                       changeEvent.captureTime.timeIntervalSince1970,
                       accuracy: 0.01,
                       "captureTime must come from ScreenChangeEvent.captureTime")
        XCTAssertGreaterThanOrEqual(first.responseTime, first.captureTime)
    }
}
