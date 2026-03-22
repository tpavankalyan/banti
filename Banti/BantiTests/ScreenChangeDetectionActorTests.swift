import XCTest
@testable import Banti

final class ScreenChangeDetectionActorTests: XCTestCase {

    private func makeFrame(seq: UInt64 = 1) -> ScreenFrameEvent {
        ScreenFrameEvent(jpeg: Data("fake".utf8), sequenceNumber: seq, displayWidth: 1920, displayHeight: 1080)
    }

    func testCapabilityIncludesScreenChangeDetection() {
        let actor = ScreenChangeDetectionActor(
            eventHub: EventHubActor(),
            config: ConfigActor(content: ""),
            differencer: MockScreenFrameDifferencer([nil])
        )
        XCTAssertTrue(actor.capabilities.contains(.screenChangeDetection))
    }

    func testFirstFrameAlwaysPublishes() async throws {
        // nil distance = no prior reference → always publish, changeDistance == nil
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCREEN_CHANGE_THRESHOLD=0.05")
        let exp = XCTestExpectation(description: "first frame published")
        let events = TestRecorder<ScreenChangeEvent>()

        _ = await hub.subscribe(ScreenChangeEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        let actor = ScreenChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockScreenFrameDifferencer([nil])
        )
        try await actor.start()

        await hub.publish(makeFrame(seq: 1))
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertNil(snapshot.first?.changeDistance, "First frame must have nil changeDistance")
        XCTAssertEqual(snapshot.first?.sequenceNumber, 1)
    }

    func testFrameBelowThresholdIsDropped() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCREEN_CHANGE_THRESHOLD=0.05")
        let events = TestRecorder<ScreenChangeEvent>()

        _ = await hub.subscribe(ScreenChangeEvent.self) { event in
            await events.append(event)
        }

        let actor = ScreenChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockScreenFrameDifferencer([0.02, 0.02])
        )
        try await actor.start()

        await hub.publish(makeFrame(seq: 1))
        await hub.publish(makeFrame(seq: 2))
        try await Task.sleep(for: .milliseconds(200))

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.count, 0, "Frames below threshold must be dropped")
    }

    func testFrameAtThresholdPublishes() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCREEN_CHANGE_THRESHOLD=0.05")
        let exp = XCTestExpectation(description: "frame at threshold published")
        let events = TestRecorder<ScreenChangeEvent>()

        _ = await hub.subscribe(ScreenChangeEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        // distance = 0.05 == threshold → should publish
        let actor = ScreenChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockScreenFrameDifferencer([0.05])
        )
        try await actor.start()

        await hub.publish(makeFrame(seq: 1))
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.changeDistance ?? -1, 0.05, accuracy: 0.001)
    }

    func testFrameAboveThresholdPublishes() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCREEN_CHANGE_THRESHOLD=0.05")
        let exp = XCTestExpectation(description: "changed frame published")
        let events = TestRecorder<ScreenChangeEvent>()

        _ = await hub.subscribe(ScreenChangeEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        let actor = ScreenChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockScreenFrameDifferencer([0.20])
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

        let actor = ScreenChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: ThrowingScreenFrameDifferencer(onCall: { callExp.fulfill() })
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
        let config = ConfigActor(content: "SCREEN_CHANGE_THRESHOLD=0.0")
        let exp = XCTestExpectation(description: "event received")
        let events = TestRecorder<ScreenChangeEvent>()

        _ = await hub.subscribe(ScreenChangeEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        let actor = ScreenChangeDetectionActor(
            eventHub: hub, config: config,
            differencer: MockScreenFrameDifferencer([0.5])
        )
        try await actor.start()

        let sourceFrame = makeFrame()
        await hub.publish(sourceFrame)
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await events.snapshot()
        guard let first = snapshot.first else { XCTFail("No event"); return }
        XCTAssertEqual(first.captureTime.timeIntervalSince1970,
                       sourceFrame.timestamp.timeIntervalSince1970,
                       accuracy: 0.001,
                       "captureTime must be forwarded from ScreenFrameEvent.timestamp")
    }
}

// Throwing helper — defined locally
private actor ThrowingScreenFrameDifferencer: ScreenFrameDifferencer {
    let onCall: @Sendable () -> Void
    init(onCall: @escaping @Sendable () -> Void) { self.onCall = onCall }
    func distance(from jpeg: Data) throws -> Float? {
        onCall()
        throw ScreenFrameDifferencerError("test error")
    }
}
