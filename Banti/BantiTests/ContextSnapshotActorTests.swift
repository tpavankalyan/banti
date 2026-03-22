import XCTest
@testable import Banti

final class ContextSnapshotActorTests: XCTestCase {

    // MARK: - Helpers

    func makeActiveApp(name: String = "Xcode", bundle: String = "com.apple.dt.Xcode") -> ActiveAppEvent {
        ActiveAppEvent(bundleIdentifier: bundle, appName: name,
                       previousBundleIdentifier: nil, previousAppName: nil)
    }

    func makeAXFocus(role: String = "AXTextField", title: String? = "Search",
                     kind: AXChangeKind = .focusChanged) -> AXFocusEvent {
        AXFocusEvent(id: UUID(), timestamp: Date(),
                     sourceModule: ModuleID("ax-focus"),
                     appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode",
                     elementRole: role, elementTitle: title, windowTitle: "Editor",
                     selectedText: nil, selectedTextLength: 0, changeKind: kind)
    }

    func makeScene(text: String = "Person sitting at desk") -> SceneDescriptionEvent {
        let now = Date()
        return SceneDescriptionEvent(text: text,
                                     captureTime: now.addingTimeInterval(-1),
                                     responseTime: now,
                                     changeDistance: 0.0)
    }

    func makeScreen(text: String = "Xcode editor with Swift code") -> ScreenDescriptionEvent {
        let now = Date()
        return ScreenDescriptionEvent(text: text,
                                      captureTime: now.addingTimeInterval(-1),
                                      responseTime: now)
    }

    func makeSegment(text: String = "hello world", isFinal: Bool = true) -> TranscriptSegmentEvent {
        TranscriptSegmentEvent(speakerLabel: "Speaker 0", text: text,
                               startTime: 0, endTime: 1, isFinal: isFinal)
    }

    /// Polls until condition returns true or 2s elapses.
    func waitUntil(_ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while await !condition() {
            guard Date() < deadline else { return }
            await Task.yield()
        }
    }

    // MARK: - Initial state

    func testSnapshotStartsEmpty() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        let snap = await actor.snapshot()

        XCTAssertNil(snap.activeApp)
        XCTAssertNil(snap.axFocus)
        XCTAssertNil(snap.sceneDescription)
        XCTAssertNil(snap.screenDescription)
        XCTAssertTrue(snap.recentTranscripts.isEmpty)
    }

    // MARK: - Event updates

    func testActiveAppEventUpdatesSnapshot() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        await hub.publish(makeActiveApp(name: "Safari"))
        await waitUntil { await actor.snapshot().activeApp != nil }

        let snap = await actor.snapshot()
        XCTAssertEqual(snap.activeApp?.appName, "Safari")
    }

    func testAXFocusEventUpdatesSnapshot() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        await hub.publish(makeAXFocus(role: "AXTextArea"))
        await waitUntil { await actor.snapshot().axFocus != nil }

        let snap = await actor.snapshot()
        XCTAssertEqual(snap.axFocus?.elementRole, "AXTextArea")
    }

    func testSceneDescriptionUpdatesSnapshot() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        await hub.publish(makeScene(text: "Two monitors on a standing desk"))
        await waitUntil { await actor.snapshot().sceneDescription != nil }

        let snap = await actor.snapshot()
        XCTAssertEqual(snap.sceneDescription?.text, "Two monitors on a standing desk")
    }

    func testScreenDescriptionUpdatesSnapshot() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        await hub.publish(makeScreen(text: "Terminal window with git log output"))
        await waitUntil { await actor.snapshot().screenDescription != nil }

        let snap = await actor.snapshot()
        XCTAssertEqual(snap.screenDescription?.text, "Terminal window with git log output")
    }

    // MARK: - Transcript segment retention

    func testFinalTranscriptSegmentIsRetained() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        await hub.publish(makeSegment(text: "let's build this feature", isFinal: true))
        await waitUntil { await actor.snapshot().recentTranscripts.count == 1 }

        let snap = await actor.snapshot()
        XCTAssertEqual(snap.recentTranscripts.first?.text, "let's build this feature")
    }

    func testNonFinalTranscriptSegmentIsNotRetained() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        await hub.publish(makeSegment(text: "in progress...", isFinal: false))
        try await Task.sleep(for: .milliseconds(200))

        let snap = await actor.snapshot()
        XCTAssertTrue(snap.recentTranscripts.isEmpty)
    }

    func testTranscriptSegmentsCappedAtFive() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        for i in 1...7 {
            await hub.publish(makeSegment(text: "sentence \(i)", isFinal: true))
        }
        // Wait until the last published segment has been processed
        await waitUntil { await actor.snapshot().recentTranscripts.last?.text == "sentence 7" }

        let snap = await actor.snapshot()
        XCTAssertEqual(snap.recentTranscripts.count, 5)
        XCTAssertEqual(snap.recentTranscripts.first?.text, "sentence 3")
        XCTAssertEqual(snap.recentTranscripts.last?.text, "sentence 7")
    }

    // MARK: - formatted()

    func testFormattedContainsActiveAppName() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        await hub.publish(makeActiveApp(name: "Xcode"))
        await waitUntil { await actor.snapshot().activeApp != nil }

        let text = await actor.snapshot().formatted()
        XCTAssertTrue(text.contains("Xcode"), "Expected 'Xcode' in: \(text)")
    }

    func testFormattedContainsTranscriptText() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        await hub.publish(makeSegment(text: "can you help me refactor this", isFinal: true))
        await waitUntil { await actor.snapshot().recentTranscripts.count == 1 }

        let text = await actor.snapshot().formatted()
        XCTAssertTrue(text.contains("can you help me refactor this"), "Expected transcript in: \(text)")
    }

    func testFormattedContainsSceneDescription() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        await hub.publish(makeScene(text: "Person looking at two screens"))
        await waitUntil { await actor.snapshot().sceneDescription != nil }

        let text = await actor.snapshot().formatted()
        XCTAssertTrue(text.contains("Person looking at two screens"), "Expected scene in: \(text)")
    }

    func testFormattedContainsScreenDescription() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        await hub.publish(makeScreen(text: "Browser with documentation open"))
        await waitUntil { await actor.snapshot().screenDescription != nil }

        let text = await actor.snapshot().formatted()
        XCTAssertTrue(text.contains("Browser with documentation open"), "Expected screen in: \(text)")
    }

    func testFormattedIsNonEmptyWithNoData() async throws {
        let hub = EventHubActor()
        let actor = ContextSnapshotActor(eventHub: hub)
        try await actor.start()

        let text = await actor.snapshot().formatted()
        XCTAssertFalse(text.isEmpty)
    }
}
