import XCTest
@testable import Banti

final class AXFocusActorTests: XCTestCase {

    // MARK: - Helpers

    private func makeActor(debounceMs: Int = 50) -> (AXFocusActor, EventHubActor) {
        let hub = EventHubActor()
        let config = ConfigActor(content: "AX_DEBOUNCE_MS=\(debounceMs)\nAX_SELECTED_TEXT_MAX_CHARS=2000")
        let actor = AXFocusActor(eventHub: hub, config: config)
        return (actor, hub)
    }

    // MARK: - Protocol conformance

    func testIdIsCorrect() {
        let (actor, _) = makeActor()
        XCTAssertEqual(actor.id.rawValue, "ax-focus")
    }

    func testCapabilitiesIncludesAXObservation() {
        let (actor, _) = makeActor()
        XCTAssertTrue(actor.capabilities.contains(.axObservation))
    }

    func testHealthIsHealthyAfterInit() async {
        let (actor, _) = makeActor()
        if case .healthy = await actor.health() { /* pass */ } else {
            XCTFail("Expected healthy after init")
        }
    }

    // MARK: - Event injection

    func testInjectEventPublishesToHub() async throws {
        let (actor, hub) = makeActor()
        let exp = XCTestExpectation(description: "AXFocusEvent received")
        let received = TestRecorder<AXFocusEvent>()

        _ = await hub.subscribe(AXFocusEvent.self) { event in
            await received.append(event)
            exp.fulfill()
        }

        await actor.injectEventForTesting(changeKind: .focusChanged, appName: "Xcode")
        await fulfillment(of: [exp], timeout: 2)

        let snapshot = await received.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.appName, "Xcode")
        XCTAssertEqual(snapshot.first?.changeKind, .focusChanged)
    }

    // MARK: - Debounce

    func testValueChangedIsDebounced() async throws {
        let (actor, hub) = makeActor(debounceMs: 50)
        let events = TestRecorder<AXFocusEvent>()

        _ = await hub.subscribe(AXFocusEvent.self) { event in
            await events.append(event)
        }

        // Fire 5 rapid valueChanged notifications within the 50ms debounce window.
        for _ in 0..<5 {
            await actor.injectValueChangedForTesting()
        }

        // Wait for debounce window to expire + buffer.
        try await Task.sleep(for: .milliseconds(250))

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.count, 1, "Rapid valueChanged should be collapsed to 1 event by debounce")
        XCTAssertEqual(snapshot.first?.changeKind, .valueChanged)
    }

    func testSelectionChangedIsNotDebounced() async throws {
        let (actor, hub) = makeActor(debounceMs: 50)
        let exp = XCTestExpectation(description: "two selection events received")
        exp.expectedFulfillmentCount = 2
        let events = TestRecorder<AXFocusEvent>()

        _ = await hub.subscribe(AXFocusEvent.self) { event in
            guard event.changeKind == .selectionChanged else { return }
            await events.append(event)
            exp.fulfill()
        }

        // Two rapid selectionChanged events — both should arrive immediately.
        await actor.injectEventForTesting(changeKind: .selectionChanged)
        await actor.injectEventForTesting(changeKind: .selectionChanged)

        await fulfillment(of: [exp], timeout: 2)

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.count, 2, "selectionChanged should not be debounced")
    }

    // MARK: - Selected text truncation

    func testSelectedTextPassedThroughWhenWithinLimit() async throws {
        let (actor, hub) = makeActor()
        let exp = XCTestExpectation(description: "event received")
        let events = TestRecorder<AXFocusEvent>()

        _ = await hub.subscribe(AXFocusEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        await actor.injectEventForTesting(
            changeKind: .selectionChanged,
            selectedText: "hello world"
        )
        await fulfillment(of: [exp], timeout: 2)

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.first?.selectedText, "hello world")
        XCTAssertEqual(snapshot.first?.selectedTextLength, 11)
    }

    func testSelectedTextTruncatedAboveMaxChars() async throws {
        let (actor, hub) = makeActor()
        let exp = XCTestExpectation(description: "event received")
        let events = TestRecorder<AXFocusEvent>()

        _ = await hub.subscribe(AXFocusEvent.self) { event in
            await events.append(event)
            exp.fulfill()
        }

        let longText = String(repeating: "a", count: 3000)
        await actor.injectEventForTesting(
            changeKind: .selectionChanged,
            selectedText: longText,
            selectedTextMaxCharsOverride: 10
        )
        await fulfillment(of: [exp], timeout: 2)

        let snapshot = await events.snapshot()
        XCTAssertNil(snapshot.first?.selectedText,
                     "selectedText should be nil when length exceeds max")
        XCTAssertEqual(snapshot.first?.selectedTextLength, 3000,
                       "selectedTextLength should still carry the full length")
    }

    // MARK: - changeKind coverage

    func testAllChangeKindsCanBePublished() async throws {
        let (actor, hub) = makeActor()
        let exp = XCTestExpectation(description: "all 3 non-debounced change kinds received")
        exp.expectedFulfillmentCount = 3
        let received = TestRecorder<AXChangeKind>()

        _ = await hub.subscribe(AXFocusEvent.self) { event in
            await received.append(event.changeKind)
            exp.fulfill()
        }

        let kinds: [AXChangeKind] = [.focusChanged, .selectionChanged, .appSwitched]
        for kind in kinds {
            await actor.injectEventForTesting(changeKind: kind)
        }

        await fulfillment(of: [exp], timeout: 2)
        let snapshot = await received.snapshot()
        XCTAssertEqual(Set(snapshot), Set(kinds))
    }
}
