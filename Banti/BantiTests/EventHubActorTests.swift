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
        let received = TestRecorder<String>()

        _ = await hub.subscribe(TestEvent.self) { event in
            await received.append(event.value)
            expectation.fulfill()
        }

        await hub.publish(TestEvent(value: "hello"))
        await fulfillment(of: [expectation], timeout: 2)
        let snapshot = await received.snapshot()
        XCTAssertEqual(snapshot.last, "hello")
    }

    func testUnsubscribeStopsDelivery() async {
        let hub = EventHubActor()
        let exp = XCTestExpectation(description: "first event")
        let received = TestRecorder<String>()

        let subID = await hub.subscribe(TestEvent.self) { _ in
            await received.append("event")
            exp.fulfill()
        }

        await hub.publish(TestEvent(value: "a"))
        await fulfillment(of: [exp], timeout: 2)

        await hub.unsubscribe(subID)
        await hub.publish(TestEvent(value: "b"))
        try? await Task.sleep(for: .milliseconds(200))
        let snapshot = await received.snapshot()
        XCTAssertEqual(snapshot.count, 1)
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
