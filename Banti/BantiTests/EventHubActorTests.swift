import XCTest
@testable import Banti

struct TestEvent: PerceptionEvent {
    let id = UUID()
    let timestamp = Date()
    let sourceModule = ModuleID("test")
    let value: String
}

final class EventHubActorTests: XCTestCase {
    func testPublishDeliversToSubscriber() async {
        let hub = EventHubActor()
        let expectation = XCTestExpectation(description: "received event")
        var received: String?

        _ = await hub.subscribe(TestEvent.self) { event in
            received = event.value
            expectation.fulfill()
        }

        await hub.publish(TestEvent(value: "hello"))
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(received, "hello")
    }

    func testUnsubscribeStopsDelivery() async {
        let hub = EventHubActor()
        let exp = XCTestExpectation(description: "first event")
        var count = 0

        let subID = await hub.subscribe(TestEvent.self) { _ in
            count += 1
            exp.fulfill()
        }

        await hub.publish(TestEvent(value: "a"))
        await fulfillment(of: [exp], timeout: 2)

        await hub.unsubscribe(subID)
        await hub.publish(TestEvent(value: "b"))
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(count, 1)
    }

    func testMultipleSubscribersReceive() async {
        let hub = EventHubActor()
        let exp1 = XCTestExpectation(description: "sub1")
        let exp2 = XCTestExpectation(description: "sub2")

        _ = await hub.subscribe(TestEvent.self) { _ in exp1.fulfill() }
        _ = await hub.subscribe(TestEvent.self) { _ in exp2.fulfill() }

        await hub.publish(TestEvent(value: "x"))
        await fulfillment(of: [exp1, exp2], timeout: 2)
    }
}
