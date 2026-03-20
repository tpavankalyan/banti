// Tests/BantiTests/EventBusTests.swift
import XCTest
@testable import BantiCore

final class EventBusTests: XCTestCase {

    func testExactTopicDelivers() async {
        let bus = EventBus()
        let expectation = expectation(description: "received")
        _ = await bus.subscribe(topic: "sensor.visual") { _ in expectation.fulfill() }
        await bus.publish(makeSpeechEvent(topic: "sensor.visual"), topic: "sensor.visual")
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testWildcardDelivers() async {
        let bus = EventBus()
        let expectation = expectation(description: "received")
        _ = await bus.subscribe(topic: "sensor.*") { _ in expectation.fulfill() }
        await bus.publish(makeSpeechEvent(topic: "sensor.audio"), topic: "sensor.audio")
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testMatchAllDelivers() async {
        let bus = EventBus()
        let expectation = expectation(description: "received")
        _ = await bus.subscribe(topic: "*") { _ in expectation.fulfill() }
        await bus.publish(makeSpeechEvent(topic: "brain.route"), topic: "brain.route")
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testNonMatchingTopicDoesNotDeliver() async {
        let bus = EventBus()
        var count = 0
        _ = await bus.subscribe(topic: "sensor.visual") { _ in count += 1 }
        await bus.publish(makeSpeechEvent(topic: "sensor.audio"), topic: "sensor.audio")
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        XCTAssertEqual(count, 0)
    }

    func testUnsubscribeStopsDelivery() async {
        let bus = EventBus()
        var count = 0
        let id = await bus.subscribe(topic: "sensor.*") { _ in count += 1 }
        await bus.publish(makeSpeechEvent(topic: "sensor.audio"), topic: "sensor.audio")
        try? await Task.sleep(nanoseconds: 20_000_000)
        await bus.unsubscribe(id)
        await bus.publish(makeSpeechEvent(topic: "sensor.visual"), topic: "sensor.visual")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(count, 1) // only the first delivery
    }

    func testWildcardDoesNotMatchParentTopic() async {
        // "sensor.*" should NOT match "sensor" (the prefix without a dot suffix)
        let bus = EventBus()
        var count = 0
        _ = await bus.subscribe(topic: "sensor.*") { _ in count += 1 }
        await bus.publish(makeSpeechEvent(topic: "sensor"), topic: "sensor")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(count, 0)
    }

    func testMultipleSubscribersAllReceive() async {
        let bus = EventBus()
        let e1 = expectation(description: "sub1")
        let e2 = expectation(description: "sub2")
        _ = await bus.subscribe(topic: "episode.bound") { _ in e1.fulfill() }
        _ = await bus.subscribe(topic: "episode.bound") { _ in e2.fulfill() }
        await bus.publish(makeSpeechEvent(topic: "episode.bound"), topic: "episode.bound")
        await fulfillment(of: [e1, e2], timeout: 1.0)
    }

    // MARK: - Helpers

    private func makeSpeechEvent(topic: String) -> BantiEvent {
        BantiEvent(source: "test", topic: topic, surprise: 0,
                   payload: .speechDetected(SpeechPayload(transcript: "hi", speakerID: nil)))
    }
}
