import XCTest
@testable import Banti

final class SceneChangeDetectionActorTests: XCTestCase {

    private func makeFrame(seq: UInt64 = 1) -> CameraFrameEvent {
        CameraFrameEvent(jpeg: Data("fake".utf8), sequenceNumber: seq, frameWidth: 640, frameHeight: 480)
    }

    func testCapabilityIncludesSceneChangeDetection() {
        let actor = SceneChangeDetectionActor(
            eventHub: EventHubActor(),
            config: ConfigActor(content: ""),
            differencer: MockFrameDifferencer([nil])
        )
        XCTAssertTrue(actor.capabilities.contains(.sceneChangeDetection))
    }

    func testFirstFrameAlwaysPublishes() async throws {
        // nil distance = no prior reference → always publish
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCENE_CHANGE_THRESHOLD=0.15")
        let exp = XCTestExpectation(description: "first frame published")
        let events = TestRecorder<SceneChangeEvent>()

        _ = await hub.subscribe(SceneChangeEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        let actor = SceneChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockFrameDifferencer([nil])   // nil = first frame
        )
        try await actor.start()

        await hub.publish(makeFrame(seq: 1))
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.changeDistance, 0.0)
        XCTAssertEqual(snapshot.first?.sequenceNumber, 1)
    }

    func testFrameBelowThresholdIsDropped() async throws {
        let hub = EventHubActor()
        // threshold=0.15, mock returns 0.05 for both frames
        let config = ConfigActor(content: "SCENE_CHANGE_THRESHOLD=0.15")
        let events = TestRecorder<SceneChangeEvent>()

        _ = await hub.subscribe(SceneChangeEvent.self) { event in
            await events.append(event)
        }

        let actor = SceneChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockFrameDifferencer([0.05, 0.05])
        )
        try await actor.start()

        await hub.publish(makeFrame(seq: 1))
        await hub.publish(makeFrame(seq: 2))
        try await Task.sleep(for: .milliseconds(200))

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.count, 0, "Frames below threshold should be dropped")
    }

    func testFrameAtOrAboveThresholdPublishes() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCENE_CHANGE_THRESHOLD=0.15")
        let exp = XCTestExpectation(description: "changed frame published")
        let events = TestRecorder<SceneChangeEvent>()

        _ = await hub.subscribe(SceneChangeEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        // distance = 0.20 >= 0.15 threshold → should publish
        let actor = SceneChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockFrameDifferencer([0.20])
        )
        try await actor.start()

        await hub.publish(makeFrame(seq: 1))
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.changeDistance ?? -1, 0.20, accuracy: 0.001)
    }

    func testDifferencerErrorDegradesHealth() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")

        let callExp = XCTestExpectation(description: "differencer called")
        // Use a custom mock that throws
        let actor = SceneChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: ThrowingFrameDifferencer(onCall: { callExp.fulfill() })
        )
        try await actor.start()

        await hub.publish(makeFrame())
        await fulfillment(of: [callExp], timeout: 3)

        let deadline = Date().addingTimeInterval(2)
        var isDegraded = false
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            if case .degraded = await actor.health() { isDegraded = true; break }
        }
        XCTAssertTrue(isDegraded, "Expected degraded health after differencer error")
    }

    func testCaptureTimeMatchesFrameTimestamp() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCENE_CHANGE_THRESHOLD=0.0")
        let exp = XCTestExpectation(description: "event received")
        let events = TestRecorder<SceneChangeEvent>()

        _ = await hub.subscribe(SceneChangeEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        let actor = SceneChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockFrameDifferencer([0.5])
        )
        try await actor.start()

        // Capture the frame event instance so we can assert the actor forwarded its exact timestamp.
        let sourceFrame = makeFrame()
        await hub.publish(sourceFrame)
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await events.snapshot()
        guard let first = snapshot.first else { XCTFail("No event"); return }
        XCTAssertEqual(first.captureTime.timeIntervalSince1970,
                       sourceFrame.timestamp.timeIntervalSince1970,
                       accuracy: 0.001,
                       "captureTime must be forwarded from CameraFrameEvent.timestamp, not set fresh")
    }
}

// Throwing helper — defined locally to keep test file self-contained
private actor ThrowingFrameDifferencer: FrameDifferencer {
    let onCall: @Sendable () -> Void
    init(onCall: @escaping @Sendable () -> Void) { self.onCall = onCall }
    func distance(from jpeg: Data) throws -> Float? {
        onCall()
        throw FrameDifferencerError("test error")
    }
}
