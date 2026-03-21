import XCTest
@testable import Banti

final class BrainActorTests: XCTestCase {
    private var tempContextPath: String!

    override func setUp() {
        let tmp = NSTemporaryDirectory()
        tempContextPath = (tmp as NSString).appendingPathComponent("banti-test-\(UUID().uuidString).md")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempContextPath)
    }

    func testSpeakDecisionPublishesBrainResponseEvent() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "CEREBRAS_API_KEY=test-key")
        let responses = TestRecorder<BrainResponseEvent>()
        let thoughts = TestRecorder<BrainThoughtEvent>()
        let responseExp = XCTestExpectation(description: "brain response")

        _ = await hub.subscribe(BrainResponseEvent.self) { event in
            await responses.append(event)
            responseExp.fulfill()
        }
        _ = await hub.subscribe(BrainThoughtEvent.self) { event in
            await thoughts.append(event)
        }

        let brain = BrainActor(
            eventHub: hub,
            config: config,
            debounceDuration: .milliseconds(50),
            contextFilePath: tempContextPath
        ) { _, input in
            BrainDecision(action: "speak", content: "Hi Pavan!")
        }

        try await brain.start()

        await hub.publish(TranscriptSegmentEvent(
            speakerLabel: "Speaker 1", text: "hey banti",
            startTime: 0, endTime: 1, isFinal: true
        ))

        await fulfillment(of: [responseExp], timeout: 2)

        let responseSnapshot = await responses.snapshot()
        XCTAssertEqual(responseSnapshot.count, 1)
        XCTAssertEqual(responseSnapshot.first?.text, "Hi Pavan!")

        let thoughtSnapshot = await thoughts.snapshot()
        XCTAssertEqual(thoughtSnapshot.first?.action, "speak")
    }

    func testThinkDecisionDoesNotPublishBrainResponseEvent() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "CEREBRAS_API_KEY=test-key")
        let responses = TestRecorder<BrainResponseEvent>()
        let thoughts = TestRecorder<BrainThoughtEvent>()
        let thoughtExp = XCTestExpectation(description: "brain thought")

        _ = await hub.subscribe(BrainResponseEvent.self) { event in
            await responses.append(event)
        }
        _ = await hub.subscribe(BrainThoughtEvent.self) { event in
            await thoughts.append(event)
            thoughtExp.fulfill()
        }

        let brain = BrainActor(
            eventHub: hub,
            config: config,
            debounceDuration: .milliseconds(50),
            contextFilePath: tempContextPath
        ) { _, _ in
            BrainDecision(action: "think", content: "He seems busy, I'll stay quiet.")
        }

        try await brain.start()

        await hub.publish(TranscriptSegmentEvent(
            speakerLabel: "Speaker 1", text: "talking to someone else",
            startTime: 0, endTime: 1, isFinal: true
        ))

        await fulfillment(of: [thoughtExp], timeout: 2)

        let responseSnapshot = await responses.snapshot()
        XCTAssertTrue(responseSnapshot.isEmpty, "Brain should NOT speak on think decision")

        let thoughtSnapshot = await thoughts.snapshot()
        XCTAssertEqual(thoughtSnapshot.count, 1)
        XCTAssertEqual(thoughtSnapshot.first?.action, "think")
        XCTAssertEqual(thoughtSnapshot.first?.text, "He seems busy, I'll stay quiet.")
    }

    func testWaitDecisionDoesNotPublishAnything() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "CEREBRAS_API_KEY=test-key")
        let responses = TestRecorder<BrainResponseEvent>()
        let thoughts = TestRecorder<BrainThoughtEvent>()
        let thoughtExp = XCTestExpectation(description: "brain thought")

        _ = await hub.subscribe(BrainResponseEvent.self) { event in
            await responses.append(event)
        }
        _ = await hub.subscribe(BrainThoughtEvent.self) { event in
            await thoughts.append(event)
            thoughtExp.fulfill()
        }

        let brain = BrainActor(
            eventHub: hub,
            config: config,
            debounceDuration: .milliseconds(50),
            contextFilePath: tempContextPath
        ) { _, _ in
            BrainDecision(action: "wait", content: "")
        }

        try await brain.start()

        await hub.publish(TranscriptSegmentEvent(
            speakerLabel: "Speaker 1", text: "background noise",
            startTime: 0, endTime: 1, isFinal: true
        ))

        await fulfillment(of: [thoughtExp], timeout: 2)

        let responseSnapshot = await responses.snapshot()
        XCTAssertTrue(responseSnapshot.isEmpty)

        let thoughtSnapshot = await thoughts.snapshot()
        XCTAssertEqual(thoughtSnapshot.first?.action, "wait")
    }

    func testContextFileIsUpdatedWithConversation() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "CEREBRAS_API_KEY=test-key")
        let thoughtExp = XCTestExpectation(description: "brain thought")

        _ = await hub.subscribe(BrainThoughtEvent.self) { _ in
            thoughtExp.fulfill()
        }

        let brain = BrainActor(
            eventHub: hub,
            config: config,
            debounceDuration: .milliseconds(50),
            contextFilePath: tempContextPath
        ) { _, _ in
            BrainDecision(action: "speak", content: "Hello!")
        }

        try await brain.start()

        await hub.publish(TranscriptSegmentEvent(
            speakerLabel: "Speaker 1", text: "hey banti",
            startTime: 0, endTime: 1, isFinal: true
        ))

        await fulfillment(of: [thoughtExp], timeout: 2)
        try? await Task.sleep(for: .milliseconds(50))

        let context = try String(contentsOfFile: tempContextPath, encoding: .utf8)
        XCTAssertTrue(context.contains("Pavan: \"hey banti\""))
        XCTAssertTrue(context.contains("(spoke) \"Hello!\""))
    }

    func testDebouncesCombinesMultipleSegments() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "CEREBRAS_API_KEY=test-key")
        let thoughtExp = XCTestExpectation(description: "brain thought")
        var receivedInputs: [String] = []

        _ = await hub.subscribe(BrainThoughtEvent.self) { _ in
            thoughtExp.fulfill()
        }

        let brain = BrainActor(
            eventHub: hub,
            config: config,
            debounceDuration: .milliseconds(100),
            contextFilePath: tempContextPath
        ) { _, input in
            receivedInputs.append(input)
            return BrainDecision(action: "wait", content: "")
        }

        try await brain.start()

        await hub.publish(TranscriptSegmentEvent(
            speakerLabel: "Speaker 1", text: "hello",
            startTime: 0, endTime: 1, isFinal: true
        ))
        await hub.publish(TranscriptSegmentEvent(
            speakerLabel: "Speaker 1", text: "banti",
            startTime: 1, endTime: 2, isFinal: true
        ))

        await fulfillment(of: [thoughtExp], timeout: 2)

        XCTAssertEqual(receivedInputs.count, 1)
        XCTAssertEqual(receivedInputs.first, "hello banti")
    }

    func testSpeaker2TranscriptsAreIgnoredToPreventSelfEcho() async throws {
        // Brain must NOT react to Speaker 2 (Banti's own voice picked up by mic).
        let hub = EventHubActor()
        let config = ConfigActor(content: "ANTHROPIC_API_KEY=test-key")
        var decisionCalled = false

        let brain = BrainActor(
            eventHub: hub,
            config: config,
            debounceDuration: .milliseconds(50),
            contextFilePath: tempContextPath
        ) { _, _ in
            decisionCalled = true
            return BrainDecision(action: "speak", content: "should not happen")
        }

        try await brain.start()

        // Publish as Speaker 2 (Banti's own voice) — should be silently dropped.
        await hub.publish(TranscriptSegmentEvent(
            speakerLabel: "Speaker 2", text: "Hello Pavan how can I help",
            startTime: 0, endTime: 1, isFinal: true
        ))

        // Wait longer than the debounce to confirm nothing fires.
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(decisionCalled, "Brain must not react to its own voice (Speaker 2)")
    }

    func testSceneDescriptionDoesNotTriggerCognitiveLoop() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "ANTHROPIC_API_KEY=test-key")
        var decisionCalled = false

        let brain = BrainActor(
            eventHub: hub,
            config: config,
            debounceDuration: .milliseconds(50),
            contextFilePath: tempContextPath
        ) { _, _ in
            decisionCalled = true
            return BrainDecision(action: "wait", content: "")
        }

        try await brain.start()

        await hub.publish(SceneDescriptionEvent(
            text: "A person at a desk with two monitors.",
            captureTime: Date(),
            responseTime: Date()
        ))

        // Wait longer than the debounce to confirm the cognitive loop never fires.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(decisionCalled, "SceneDescriptionEvent must not trigger the cognitive loop")
    }

    func testSceneDescriptionIsWrittenToContextFile() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "ANTHROPIC_API_KEY=test-key")

        let brain = BrainActor(
            eventHub: hub,
            config: config,
            debounceDuration: .milliseconds(50),
            contextFilePath: tempContextPath
        ) { _, _ in
            BrainDecision(action: "wait", content: "")
        }

        try await brain.start()

        await hub.publish(SceneDescriptionEvent(
            text: "Coffee cup on the desk.",
            captureTime: Date(),
            responseTime: Date()
        ))

        // Poll the file until the write completes or timeout is reached.
        let deadline = Date().addingTimeInterval(3)
        var found = false
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            let context = (try? String(contentsOfFile: tempContextPath, encoding: .utf8)) ?? ""
            if context.contains("Coffee cup on the desk.") {
                found = true
                break
            }
        }

        XCTAssertTrue(found, "Scene description was not written to context.md within timeout")

        let context = try String(contentsOfFile: tempContextPath, encoding: .utf8)
        XCTAssertTrue(context.contains("(scene) \"Coffee cup on the desk.\""), "Context must contain correctly formatted scene entry")
    }
}
