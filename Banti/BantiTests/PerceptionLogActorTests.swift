// Banti/BantiTests/PerceptionLogActorTests.swift
import XCTest
@testable import Banti

final class PerceptionLogActorTests: XCTestCase {

    func waitUntil(_ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while await !condition() {
            guard Date() < deadline else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Helpers

    func makeScreenDesc(text: String, dist: Float? = 0.5) -> ScreenDescriptionEvent {
        ScreenDescriptionEvent(text: text, captureTime: Date(), responseTime: Date(), changeDistance: dist)
    }

    func makeSceneDesc(text: String, dist: Float = 0.5) -> SceneDescriptionEvent {
        SceneDescriptionEvent(text: text, captureTime: Date(), responseTime: Date(), changeDistance: dist)
    }

    func makeSegment(text: String) -> TranscriptSegmentEvent {
        TranscriptSegmentEvent(speakerLabel: "Speaker 0", text: text, startTime: 0, endTime: 1, isFinal: true)
    }

    func makeAXFocus(app: String = "Xcode", role: String = "AXTextField", title: String? = "main.swift") -> AXFocusEvent {
        AXFocusEvent(id: UUID(), timestamp: Date(), sourceModule: ModuleID("ax-focus"),
                     appName: app, bundleIdentifier: "com.test", elementRole: role,
                     elementTitle: title, windowTitle: nil, selectedText: nil,
                     selectedTextLength: 0, changeKind: .focusChanged)
    }

    func makeActiveApp(name: String = "Xcode") -> ActiveAppEvent {
        ActiveAppEvent(bundleIdentifier: "com.test", appName: name,
                       previousBundleIdentifier: nil, previousAppName: nil)
    }

    // MARK: - Basic ingestion

    func testScreenDescEventCreatesEntry() async throws {
        let hub = EventHubActor()
        let log = PerceptionLogActor(eventHub: hub)
        try await log.start()

        await hub.publish(makeScreenDesc(text: "Xcode build error"))
        await waitUntil { await log.log().entries.count == 1 }

        let entries = await log.log().entries
        XCTAssertEqual(entries[0].kind, .screenDescription)
        XCTAssertEqual(entries[0].summary, "Xcode build error")
        XCTAssertEqual(entries[0].changeDistance, 0.5)
    }

    func testSceneDescEventCreatesEntry() async throws {
        let hub = EventHubActor()
        let log = PerceptionLogActor(eventHub: hub)
        try await log.start()

        await hub.publish(makeSceneDesc(text: "Person at desk", dist: 0.7))
        await waitUntil { await log.log().entries.count == 1 }

        let entries = await log.log().entries
        XCTAssertEqual(entries[0].kind, .sceneDescription)
        XCTAssertEqual(entries[0].changeDistance, 0.7)
    }

    func testTranscriptSegmentCreatesEntry() async throws {
        let hub = EventHubActor()
        let log = PerceptionLogActor(eventHub: hub)
        try await log.start()

        await hub.publish(makeSegment(text: "hello world"))
        await waitUntil { await log.log().entries.count == 1 }

        let entries = await log.log().entries
        XCTAssertEqual(entries[0].kind, .transcript)
        XCTAssertTrue(entries[0].summary.contains("hello world"))
    }

    // MARK: - Age eviction

    func testAgeEvictionRemovesOldEntries() async throws {
        let hub = EventHubActor()
        let log = PerceptionLogActor(eventHub: hub, windowSeconds: 0.1)
        try await log.start()

        await hub.publish(makeScreenDesc(text: "old entry"))
        await waitUntil { await log.log().entries.count == 1 }

        try await Task.sleep(for: .milliseconds(150))

        await hub.publish(makeScreenDesc(text: "new entry"))
        await waitUntil { await log.log().entries.last?.summary == "new entry" }

        let entries = await log.log().entries
        XCTAssertFalse(entries.contains { $0.summary == "old entry" }, "Old entry should have been evicted")
        XCTAssertTrue(entries.contains { $0.summary == "new entry" })
    }

    // MARK: - Cap eviction (age-evict first, then cap)

    func testCapEvictionKeepsNewest() async throws {
        let hub = EventHubActor()
        let log = PerceptionLogActor(eventHub: hub, maxEntries: 3)
        try await log.start()

        for i in 1...4 {
            await hub.publish(makeScreenDesc(text: "entry \(i)"))
        }
        await waitUntil { await log.log().entries.contains { $0.summary == "entry 4" } }

        let entries = await log.log().entries
        XCTAssertEqual(entries.count, 3)
        XCTAssertFalse(entries.contains { $0.summary == "entry 1" }, "Oldest should be dropped")
        XCTAssertTrue(entries.contains { $0.summary == "entry 4" })
    }

    // MARK: - AXFocus deduplication

    func testAXFocusDedupUpdatesTimestamp() async throws {
        let hub = EventHubActor()
        let log = PerceptionLogActor(eventHub: hub)
        try await log.start()

        let e1 = makeAXFocus(app: "Xcode", role: "AXTextField", title: "main.swift")
        await hub.publish(e1)
        await waitUntil { await log.log().entries.count == 1 }
        let firstTime = await log.log().entries[0].timestamp

        try await Task.sleep(for: .milliseconds(50))

        let e2 = makeAXFocus(app: "Xcode", role: "AXTextField", title: "main.swift")
        await hub.publish(e2)
        try await Task.sleep(for: .milliseconds(100))

        let entries = await log.log().entries
        XCTAssertEqual(entries.count, 1, "Duplicate AXFocus should not add new entry")
        XCTAssertGreaterThan(entries[0].timestamp, firstTime, "Timestamp should be updated")
    }

    func testAXFocusNilTitleNotDeduped() async throws {
        let hub = EventHubActor()
        let log = PerceptionLogActor(eventHub: hub)
        try await log.start()

        await hub.publish(makeAXFocus(title: nil))
        await waitUntil { await log.log().entries.count == 1 }
        await hub.publish(makeAXFocus(title: nil))
        await waitUntil { await log.log().entries.count == 2 }

        let dedupCount = await log.log().entries.count
        XCTAssertEqual(dedupCount, 2)
    }

    // MARK: - Active app / AX focus stored separately

    func testActiveAppStoredOnLog() async throws {
        let hub = EventHubActor()
        let log = PerceptionLogActor(eventHub: hub)
        try await log.start()

        await hub.publish(makeActiveApp(name: "Safari"))
        await waitUntil { await log.log().activeApp != nil }

        let activeAppName = await log.log().activeApp?.appName
        XCTAssertEqual(activeAppName, "Safari")
    }

    // MARK: - Formatted output

    func testFormattedContainsScreenEntry() async throws {
        let hub = EventHubActor()
        let log = PerceptionLogActor(eventHub: hub)
        try await log.start()

        await hub.publish(makeScreenDesc(text: "Build error on line 42"))
        await waitUntil { await log.log().entries.count == 1 }

        let formatted = await log.log().formatted()
        XCTAssertTrue(formatted.contains("Build error on line 42"))
        XCTAssertTrue(formatted.contains("SCREEN"))
    }

    func testFormattedSplitsOlderAndRecentSegments() async throws {
        let hub = EventHubActor()
        let log = PerceptionLogActor(eventHub: hub, recentWindowSeconds: 0.2)
        try await log.start()

        await hub.publish(makeScreenDesc(text: "old screen"))
        await waitUntil { await log.log().entries.count == 1 }

        try await Task.sleep(for: .milliseconds(300))

        await hub.publish(makeScreenDesc(text: "new screen"))
        await waitUntil { await log.log().entries.count == 2 }

        let formatted = await log.log().formatted()
        let olderSection = formatted.components(separatedBy: "=== Perception Log — Recent")[0]
        let recentSection = formatted.components(separatedBy: "=== Perception Log — Recent").dropFirst().first ?? ""

        XCTAssertTrue(olderSection.contains("old screen"))
        XCTAssertTrue(recentSection.contains("new screen"))
    }
}
