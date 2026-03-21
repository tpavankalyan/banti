import XCTest
@testable import Banti

final class CameraFrameActorTests: XCTestCase {
    func testCapabilitiesIncludesVideoCapture() {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = CameraFrameActor(eventHub: hub, config: config)
        XCTAssertTrue(actor.capabilities.contains(.videoCapture))
    }

    func testIdIsCorrect() {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = CameraFrameActor(eventHub: hub, config: config)
        XCTAssertEqual(actor.id.rawValue, "camera-capture")
    }

    func testReplayFramesReturnsEmptyWhenNothingPublished() async {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = CameraFrameActor(eventHub: hub, config: config)
        let frames = await actor.replayFrames(after: 0)
        XCTAssertTrue(frames.isEmpty)
    }

    func testReplayFramesReturnsFramesAfterSeq() async {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = CameraFrameActor(eventHub: hub, config: config)

        await actor.injectFrameForTesting(jpeg: Data("frame1".utf8), seq: 1)
        await actor.injectFrameForTesting(jpeg: Data("frame2".utf8), seq: 2)
        await actor.injectFrameForTesting(jpeg: Data("frame3".utf8), seq: 3)

        let frames = await actor.replayFrames(after: 1)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].seq, 2)
        XCTAssertEqual(frames[1].seq, 3)
    }

    func testReplayBufferEvictsOldFrames() async {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = CameraFrameActor(eventHub: hub, config: config)

        // Inject 31 frames — one more than the maxReplayFrames (30).
        for i in UInt64(1)...31 {
            await actor.injectFrameForTesting(jpeg: Data("frame\(i)".utf8), seq: i)
        }

        let frames = await actor.replayFrames(after: 0)
        XCTAssertEqual(frames.count, 30)
        XCTAssertEqual(frames.first?.seq, 2, "Oldest frame should be evicted")
        XCTAssertEqual(frames.last?.seq, 31)
    }

    func testHealthIsHealthyAfterInit() async {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = CameraFrameActor(eventHub: hub, config: config)
        let health = await actor.health()
        if case .healthy = health { /* pass */ } else {
            XCTFail("Expected healthy, got \(health.label)")
        }
    }
}
