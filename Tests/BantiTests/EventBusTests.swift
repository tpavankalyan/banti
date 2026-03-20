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
        let notCalled = expectation(description: "should not be called")
        notCalled.isInverted = true
        _ = await bus.subscribe(topic: "sensor.visual") { _ in notCalled.fulfill() }
        await bus.publish(makeSpeechEvent(topic: "sensor.audio"), topic: "sensor.audio")
        await fulfillment(of: [notCalled], timeout: 0.05)
    }

    func testUnsubscribeStopsDelivery() async {
        let bus = EventBus()
        let firstDelivery = expectation(description: "first delivery")
        let secondDelivery = expectation(description: "should not be delivered after unsubscribe")
        secondDelivery.isInverted = true

        let id = await bus.subscribe(topic: "sensor.*") { _ in
            firstDelivery.fulfill()
        }
        await bus.publish(makeSpeechEvent(topic: "sensor.audio"), topic: "sensor.audio")
        await fulfillment(of: [firstDelivery], timeout: 1.0)

        await bus.unsubscribe(id)
        await bus.publish(makeSpeechEvent(topic: "sensor.visual"), topic: "sensor.visual")
        await fulfillment(of: [secondDelivery], timeout: 0.05)
    }

    func testWildcardDoesNotMatchParentTopic() async {
        // "sensor.*" should NOT match "sensor" (the prefix without a dot suffix)
        let bus = EventBus()
        let notCalled = expectation(description: "sensor.* should not match bare sensor")
        notCalled.isInverted = true
        _ = await bus.subscribe(topic: "sensor.*") { _ in notCalled.fulfill() }
        await bus.publish(makeSpeechEvent(topic: "sensor"), topic: "sensor")
        await fulfillment(of: [notCalled], timeout: 0.05)
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
