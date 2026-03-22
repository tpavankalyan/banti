# Cognitive Pipeline Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the reactive, flat-context cognitive pipeline with a proactive, streaming one: temporal perception log → event-driven Claude tool-use (speak/silent FLAG) → Cartesia WebSocket TTS with epoch-based barge-in.

**Architecture:** `PerceptionLogActor` maintains a 90s rolling log of typed perception entries fed by description events. `CognitiveCoreActor` subscribes to description/turn events, debounces, calls Claude streaming with prompt caching, uses `speak` tool-use as the FLAG mechanism, and sentence-chunks text to `StreamingTTSActor`. `StreamingTTSActor` forwards chunks to Cartesia WebSocket; `InterruptEvent` (with epoch) discards stale audio on barge-in.

**Tech Stack:** Swift actors, Claude API (streaming + prompt caching), Cartesia WebSocket TTS, AVAudioEngine/AVAudioPlayerNode, XCTest

---

## File Map

**Create:**
- `Banti/Banti/Core/Events/SpeakChunkEvent.swift`
- `Banti/Banti/Core/Events/InterruptEvent.swift`
- `Banti/Banti/Core/PerceptionLogActor.swift`
- `Banti/Banti/Core/CognitiveCoreActor.swift`
- `Banti/Banti/Core/StreamingTTSActor.swift`
- `Banti/BantiTests/PerceptionLogActorTests.swift`
- `Banti/BantiTests/CognitiveCoreActorTests.swift`
- `Banti/BantiTests/StreamingTTSActorTests.swift`

**Modify:**
- `Banti/Banti/Core/Events/AgentResponseEvent.swift` — add `sourceModule` param to init
- `Banti/Banti/Config/Environment.swift` — add new env keys
- `Banti/Banti/Core/EventLoggerActor.swift` — log new event types
- `Banti/Banti/BantiApp.swift` — swap actors in bootstrap

**Delete (Task 3, before CognitiveCoreActor — avoids AgentLLMProvider name collision):**
- `Banti/Banti/Core/AgentBridgeActor.swift`
- `Banti/BantiTests/AgentBridgeActorTests.swift`

**Delete (Task 5):**
- `Banti/Banti/Core/ContextSnapshotActor.swift`
- `Banti/Banti/Core/TTSActor.swift`
- `Banti/BantiTests/ContextSnapshotActorTests.swift`
- `Banti/BantiTests/TTSActorTests.swift`

**Project regen note:** The project uses XcodeGen (`Banti/project.yml`). After creating or deleting any `.swift` file, run:
```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti && xcodegen generate
```
Then run tests with:
```bash
xcodebuild test -project Banti.xcodeproj -scheme Banti \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BantiTests/<TestClass> \
  2>&1 | grep -E "(Test Case|error:|passed|failed)" | tail -30
```

---

## Task 1: New Event Types + AgentResponseEvent + Env Keys

**Files:**
- Create: `Banti/Banti/Core/Events/SpeakChunkEvent.swift`
- Create: `Banti/Banti/Core/Events/InterruptEvent.swift`
- Modify: `Banti/Banti/Core/Events/AgentResponseEvent.swift`
- Modify: `Banti/Banti/Config/Environment.swift`

- [ ] **Step 1: Create SpeakChunkEvent**

```swift
// Banti/Banti/Core/Events/SpeakChunkEvent.swift
import Foundation

/// Published by CognitiveCoreActor for each sentence-complete text chunk to speak.
struct SpeakChunkEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let text: String
    let epoch: Int

    init(text: String, epoch: Int) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("cognitive-core")
        self.text = text
        self.epoch = epoch
    }
}
```

- [ ] **Step 2: Create InterruptEvent**

```swift
// Banti/Banti/Core/Events/InterruptEvent.swift
import Foundation

/// Published by CognitiveCoreActor when barge-in occurs.
/// StreamingTTSActor sets (not increments) its epoch to this value.
struct InterruptEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let epoch: Int

    init(epoch: Int) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("cognitive-core")
        self.epoch = epoch
    }
}
```

- [ ] **Step 3: Add sourceModule init to AgentResponseEvent**

Add a new designated initializer that accepts `sourceModule`. Keep the old one for backward compat.

```swift
// Add inside AgentResponseEvent, after the existing init:
init(userText: String, responseText: String, sourceModule: ModuleID) {
    self.id = UUID()
    self.timestamp = Date()
    self.sourceModule = sourceModule
    self.userText = userText
    self.responseText = responseText
}
```

- [ ] **Step 4: Add env keys to Environment.swift**

```swift
// Add to EnvKey enum:
static let claudeModel                  = "CLAUDE_MODEL"
static let claudeMaxTokens              = "CLAUDE_MAX_TOKENS"
static let screenProactiveThreshold     = "SCREEN_PROACTIVE_THRESHOLD"
static let sceneProactiveThreshold      = "SCENE_PROACTIVE_THRESHOLD"
static let cognitiveScreenInterval      = "COGNITIVE_SCREEN_INTERVAL"
static let cognitiveSceneInterval       = "COGNITIVE_SCENE_INTERVAL"
static let cognitiveAppInterval         = "COGNITIVE_APP_INTERVAL"
static let perceptionLogMaxEntries      = "PERCEPTION_LOG_MAX_ENTRIES"
static let perceptionLogWindowSeconds   = "PERCEPTION_LOG_WINDOW_SECONDS"
```

- [ ] **Step 5: Regen project and verify build**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti && xcodegen generate
xcodebuild build -project Banti.xcodeproj -scheme Banti \
  -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E "(error:|BUILD)" | tail -10
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add Banti/Banti/Core/Events/SpeakChunkEvent.swift \
        Banti/Banti/Core/Events/InterruptEvent.swift \
        Banti/Banti/Core/Events/AgentResponseEvent.swift \
        Banti/Banti/Config/Environment.swift
git commit -m "feat: add SpeakChunkEvent, InterruptEvent; expand AgentResponseEvent and env keys"
```

---

## Task 2: PerceptionLogActor (TDD)

**Files:**
- Create: `Banti/BantiTests/PerceptionLogActorTests.swift`
- Create: `Banti/Banti/Core/PerceptionLogActor.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Banti/BantiTests/PerceptionLogActorTests.swift
import XCTest
@testable import Banti

final class PerceptionLogActorTests: XCTestCase {

    func waitUntil(_ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while await !condition() {
            guard Date() < deadline else { return }
            await Task.yield()
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
        await waitUntil { await log.log().entries.count == 3 }

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

        XCTAssertEqual(await log.log().entries.count, 2)
    }

    // MARK: - Active app / AX focus stored separately

    func testActiveAppStoredOnLog() async throws {
        let hub = EventHubActor()
        let log = PerceptionLogActor(eventHub: hub)
        try await log.start()

        await hub.publish(makeActiveApp(name: "Safari"))
        await waitUntil { await log.log().activeApp != nil }

        XCTAssertEqual(await log.log().activeApp?.appName, "Safari")
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
```

- [ ] **Step 2: Regen project, run tests to verify they fail**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti && xcodegen generate
xcodebuild test -project Banti.xcodeproj -scheme Banti \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BantiTests/PerceptionLogActorTests \
  2>&1 | grep -E "(error:|Test Case)" | head -20
```
Expected: compile errors — `PerceptionLogActor` not found.

- [ ] **Step 3: Implement PerceptionLogActor**

```swift
// Banti/Banti/Core/PerceptionLogActor.swift
import Foundation

// MARK: - Value types

enum PerceptionLogKind: Equatable {
    case screenDescription, sceneDescription, transcript, appSwitch, axFocus
}

struct PerceptionLogEntry {
    let timestamp: Date
    let kind: PerceptionLogKind
    let summary: String
    let changeDistance: Float?
}

struct PerceptionLog {
    let entries: [PerceptionLogEntry]
    let activeApp: ActiveAppEvent?
    let axFocus: AXFocusEvent?
    let recentWindowSeconds: TimeInterval

    func formatted() -> String {
        let now = Date()
        let cutoff = now.addingTimeInterval(-recentWindowSeconds)
        let older = entries.filter { $0.timestamp < cutoff }
        let recent = entries.filter { $0.timestamp >= cutoff }

        var lines: [String] = []

        if !older.isEmpty {
            lines.append("=== Perception Log — Older (>\(Int(recentWindowSeconds))s) ===")
            for e in older { lines.append(formatEntry(e, now: now)) }
        }
        if !recent.isEmpty {
            lines.append("=== Perception Log — Recent (<\(Int(recentWindowSeconds))s) ===")
            for e in recent { lines.append(formatEntry(e, now: now)) }
        }

        lines.append("=== Active Now ===")
        if let app = activeApp { lines.append("App: \(app.appName) (\(app.bundleIdentifier))") }
        if let ax = axFocus {
            var line = "Focus: \(ax.elementRole)"
            if let t = ax.elementTitle { line += " — \(t)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func formatEntry(_ e: PerceptionLogEntry, now: Date) -> String {
        let age = max(0, Int(now.timeIntervalSince(e.timestamp)))
        let kindStr: String
        switch e.kind {
        case .screenDescription: kindStr = "SCREEN     "
        case .sceneDescription:  kindStr = "SCENE      "
        case .transcript:        kindStr = "TRANSCRIPT "
        case .appSwitch:         kindStr = "APP        "
        case .axFocus:           kindStr = "AX_FOCUS   "
        }
        var line = "[\(String(format: "%3d", age))s ago] \(kindStr)"
        if let d = e.changeDistance { line += " dist=\(String(format: "%.2f", d))" }
        line += " | \(e.summary)"
        return line
    }
}

// MARK: - Actor

actor PerceptionLogActor: BantiModule {
    nonisolated let id = ModuleID("perception-log")
    nonisolated let capabilities: Set<Capability> = []

    private let eventHub: EventHubActor
    private let windowSeconds: TimeInterval
    private let maxEntries: Int
    let recentWindowSeconds: TimeInterval

    private var entries: [PerceptionLogEntry] = []
    private var latestActiveApp: ActiveAppEvent?
    private var latestAXFocus: AXFocusEvent?
    private var subscriptionIDs: [SubscriptionID] = []
    private var _health: ModuleHealth = .healthy

    init(eventHub: EventHubActor,
         windowSeconds: TimeInterval = 90,
         maxEntries: Int = 50,
         recentWindowSeconds: TimeInterval = 30) {
        self.eventHub = eventHub
        self.windowSeconds = windowSeconds
        self.maxEntries = maxEntries
        self.recentWindowSeconds = recentWindowSeconds
    }

    func start() async throws {
        subscriptionIDs.append(await eventHub.subscribe(ScreenDescriptionEvent.self) { [weak self] e in await self?.handle(e) })
        subscriptionIDs.append(await eventHub.subscribe(SceneDescriptionEvent.self)  { [weak self] e in await self?.handle(e) })
        subscriptionIDs.append(await eventHub.subscribe(TranscriptSegmentEvent.self) { [weak self] e in await self?.handle(e) })
        subscriptionIDs.append(await eventHub.subscribe(ActiveAppEvent.self)         { [weak self] e in await self?.handle(e) })
        subscriptionIDs.append(await eventHub.subscribe(AXFocusEvent.self)           { [weak self] e in await self?.handle(e) })
        _health = .healthy
    }

    func stop() async {
        for s in subscriptionIDs { await eventHub.unsubscribe(s) }
        subscriptionIDs.removeAll()
    }

    func health() async -> ModuleHealth { _health }

    func log() -> PerceptionLog {
        PerceptionLog(entries: entries, activeApp: latestActiveApp,
                      axFocus: latestAXFocus, recentWindowSeconds: recentWindowSeconds)
    }

    // MARK: - Handlers

    private func handle(_ e: ScreenDescriptionEvent) {
        insert(PerceptionLogEntry(timestamp: e.timestamp, kind: .screenDescription,
                                  summary: e.text, changeDistance: e.changeDistance))
    }

    private func handle(_ e: SceneDescriptionEvent) {
        insert(PerceptionLogEntry(timestamp: e.timestamp, kind: .sceneDescription,
                                  summary: e.text, changeDistance: Float?(e.changeDistance)))
    }

    private func handle(_ e: TranscriptSegmentEvent) {
        guard e.isFinal else { return }
        insert(PerceptionLogEntry(timestamp: e.timestamp, kind: .transcript,
                                  summary: "user: \(e.text)", changeDistance: nil))
    }

    private func handle(_ e: ActiveAppEvent) {
        latestActiveApp = e
        insert(PerceptionLogEntry(timestamp: e.timestamp, kind: .appSwitch,
                                  summary: "\(e.appName) (\(e.bundleIdentifier))", changeDistance: nil))
    }

    private func handle(_ e: AXFocusEvent) {
        latestAXFocus = e
        // Dedup: only skip if all three fields are non-nil and match last axFocus entry
        if let last = entries.last(where: { $0.kind == .axFocus }),
           let title = e.elementTitle,
           last.summary.contains(e.appName),
           last.summary.contains(e.elementRole),
           last.summary.contains(title) {
            // Update timestamp in-place
            if let idx = entries.lastIndex(where: { $0.kind == .axFocus }) {
                let updated = PerceptionLogEntry(timestamp: e.timestamp, kind: .axFocus,
                                                  summary: entries[idx].summary, changeDistance: nil)
                entries[idx] = updated
            }
            return
        }
        var summary = "\(e.appName) — \(e.elementRole)"
        if let t = e.elementTitle { summary += " \"\(t)\"" }
        insert(PerceptionLogEntry(timestamp: e.timestamp, kind: .axFocus,
                                  summary: summary, changeDistance: nil))
    }

    // MARK: - Insertion with eviction

    private func insert(_ entry: PerceptionLogEntry) {
        // Age-evict first
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        entries.removeAll { $0.timestamp < cutoff }
        entries.append(entry)
        // Cap after age-evict
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}
```

- [ ] **Step 4: Regen and run tests**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti && xcodegen generate
xcodebuild test -project Banti.xcodeproj -scheme Banti \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BantiTests/PerceptionLogActorTests \
  2>&1 | grep -E "(Test Case|error:|passed|failed)" | tail -20
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Banti/Banti/Core/PerceptionLogActor.swift \
        Banti/BantiTests/PerceptionLogActorTests.swift
git commit -m "feat: add PerceptionLogActor with temporal rolling log and segment formatting"
```

---

## Task 3: CognitiveCoreActor — Protocol + Trigger + Silent/Speak paths (TDD)

**Files:**
- Create: `Banti/BantiTests/CognitiveCoreActorTests.swift`
- Create: `Banti/Banti/Core/CognitiveCoreActor.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Banti/BantiTests/CognitiveCoreActorTests.swift
import XCTest
@testable import Banti

// MARK: - Stubs

/// Configurable stub — emits a fixed sequence of events and records calls.
actor StubStreamingLLMProvider: AgentLLMProvider {
    var responseEvents: [AgentStreamEvent] = [.silent]
    private(set) var callCount = 0
    private(set) var lastTriggerSource: String?

    func streamResponse(
        systemPrompt: CachedPromptBlock,
        olderContext: CachedPromptBlock,
        recentContext: String,
        triggerSource: String
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        callCount += 1
        lastTriggerSource = triggerSource
        let events = responseEvents
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Never finishes — used to test barge-in cancellation.
actor InfiniteStreamingStub: AgentLLMProvider {
    private(set) var callCount = 0

    func streamResponse(
        systemPrompt: CachedPromptBlock,
        olderContext: CachedPromptBlock,
        recentContext: String,
        triggerSource: String
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        callCount += 1
        return AsyncThrowingStream { _ in
            // Never yields or finishes — hangs until task is cancelled
        }
    }
}

// MARK: - Helpers

final class CognitiveCoreActorTests: XCTestCase {

    func waitUntil(_ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while await !condition() {
            guard Date() < deadline else { return }
            await Task.yield()
        }
    }

    func makeHub() -> EventHubActor { EventHubActor() }

    func makeLog(hub: EventHubActor) async throws -> PerceptionLogActor {
        let log = PerceptionLogActor(eventHub: hub)
        try await log.start()
        return log
    }

    func makeTurnEnded(text: String = "hello") -> TurnEndedEvent { TurnEndedEvent(text: text) }
    func makeTurnStarted() -> TurnStartedEvent { TurnStartedEvent() }

    func makeScreenDesc(dist: Float = 0.8) -> ScreenDescriptionEvent {
        ScreenDescriptionEvent(text: "screen changed", captureTime: Date(), responseTime: Date(), changeDistance: dist)
    }

    // MARK: - TurnEndedEvent always fires

    func testTurnEndedAlwaysTriggers() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        await hub.publish(makeTurnEnded())
        await waitUntil { await stub.callCount == 1 }
        await hub.publish(makeTurnEnded())
        await waitUntil { await stub.callCount == 2 }

        XCTAssertEqual(await stub.callCount, 2)
    }

    // MARK: - Screen event debounce

    func testScreenEventDebounced() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        // 1s interval so two events fired 100ms apart result in only one call
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub,
                                      screenInterval: 1.0, screenThreshold: 0.3)
        try await core.start()

        await hub.publish(makeScreenDesc(dist: 0.8))
        await hub.publish(makeScreenDesc(dist: 0.8))
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(await stub.callCount, 1, "Second event within interval should be coalesced")
    }

    func testScreenEventBelowThresholdNotTriggered() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub,
                                      screenThreshold: 0.5)
        try await core.start()

        await hub.publish(makeScreenDesc(dist: 0.1)) // below threshold
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(await stub.callCount, 0)
    }

    // MARK: - Silent path

    func testSilentPathPublishesNothingToTTS() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        stub.responseEvents = [.silent]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var chunks: [SpeakChunkEvent] = []
        let subID = await hub.subscribe(SpeakChunkEvent.self) { chunks.append($0) }

        await hub.publish(makeTurnEnded())
        await waitUntil { await stub.callCount == 1 }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(chunks.isEmpty)
        await hub.unsubscribe(subID)
    }

    func testSilentPathPublishesNoAgentResponse() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        stub.responseEvents = [.silent]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var responses: [AgentResponseEvent] = []
        let subID = await hub.subscribe(AgentResponseEvent.self) { responses.append($0) }

        await hub.publish(makeTurnEnded())
        await waitUntil { await stub.callCount == 1 }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(responses.isEmpty)
        await hub.unsubscribe(subID)
    }

    // MARK: - Speak path

    func testSpeakPathPublishesSpeakChunk() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        // 16+ chars to pass minimum length check, ends with period
        stub.responseEvents = [.speakChunk("This is a response."), .speakDone]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var chunks: [SpeakChunkEvent] = []
        let subID = await hub.subscribe(SpeakChunkEvent.self) { chunks.append($0) }

        await hub.publish(makeTurnEnded(text: "help me"))
        await waitUntil { !chunks.isEmpty }

        XCTAssertTrue(chunks[0].text.contains("This is a response"))
        await hub.unsubscribe(subID)
    }

    func testSpeakPathPublishesAgentResponseOnDone() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        stub.responseEvents = [.speakChunk("Use a computed property."), .speakDone]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var responses: [AgentResponseEvent] = []
        let subID = await hub.subscribe(AgentResponseEvent.self) { responses.append($0) }

        await hub.publish(makeTurnEnded(text: "how do I do X?"))
        await waitUntil { !responses.isEmpty }

        XCTAssertEqual(responses[0].userText, "how do I do X?")
        XCTAssertEqual(responses[0].responseText, "Use a computed property.")
        await hub.unsubscribe(subID)
    }

    func testProactiveSpeakHasEmptyUserText() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        stub.responseEvents = [.speakChunk("Your build just failed."), .speakDone]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub,
                                      screenInterval: 0, screenThreshold: 0)
        try await core.start()

        var responses: [AgentResponseEvent] = []
        let subID = await hub.subscribe(AgentResponseEvent.self) { responses.append($0) }

        await hub.publish(makeScreenDesc(dist: 0.9))
        await waitUntil { !responses.isEmpty }

        XCTAssertEqual(responses[0].userText, "")
        await hub.unsubscribe(subID)
    }

    // MARK: - Sentence boundary chunking

    func testShortChunkAccumulatesUntilSentenceBoundary() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        // Short fragments that together exceed 15 chars and end with period
        stub.responseEvents = [
            .speakChunk("Use a "),
            .speakChunk("computed "),
            .speakChunk("property."),
            .speakDone
        ]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var chunks: [SpeakChunkEvent] = []
        let subID = await hub.subscribe(SpeakChunkEvent.self) { chunks.append($0) }

        await hub.publish(makeTurnEnded())
        await waitUntil { !chunks.isEmpty }
        try await Task.sleep(for: .milliseconds(100))

        // Should be one flushed chunk (accumulated then flushed at period)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].text.contains("computed property"))
        await hub.unsubscribe(subID)
    }

    func testRemainingBufferFlushedOnDone() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        // No sentence-ending punctuation — should flush on speakDone
        stub.responseEvents = [.speakChunk("sure"), .speakDone]
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var chunks: [SpeakChunkEvent] = []
        let subID = await hub.subscribe(SpeakChunkEvent.self) { chunks.append($0) }

        await hub.publish(makeTurnEnded())
        await waitUntil { !chunks.isEmpty }

        XCTAssertEqual(chunks[0].text, "sure")
        await hub.unsubscribe(subID)
    }

    // MARK: - Barge-in

    func testBargeInPublishesInterruptEvent() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = InfiniteStreamingStub()
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var interrupt: InterruptEvent?
        let subID = await hub.subscribe(InterruptEvent.self) { interrupt = $0 }

        await hub.publish(makeTurnEnded())
        await waitUntil { await stub.callCount > 0 }

        await hub.publish(makeTurnStarted())
        await waitUntil { interrupt != nil }

        XCTAssertNotNil(interrupt)
        XCTAssertEqual(interrupt?.epoch, 1)
        await hub.unsubscribe(subID)
    }

    func testBargeInWithNoActiveCallStillPublishesInterrupt() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var interrupt: InterruptEvent?
        let subID = await hub.subscribe(InterruptEvent.self) { interrupt = $0 }

        await hub.publish(makeTurnStarted()) // No active stream
        await waitUntil { interrupt != nil }

        XCTAssertNotNil(interrupt)
        await hub.unsubscribe(subID)
    }

    func testEpochIncrementedOnEachBargeIn() async throws {
        let hub = makeHub()
        let log = try await makeLog(hub: hub)
        let stub = StubStreamingLLMProvider()
        let core = CognitiveCoreActor(eventHub: hub, perceptionLog: log, provider: stub)
        try await core.start()

        var interrupts: [InterruptEvent] = []
        let subID = await hub.subscribe(InterruptEvent.self) { interrupts.append($0) }

        await hub.publish(makeTurnStarted())
        await hub.publish(makeTurnStarted())
        await waitUntil { interrupts.count == 2 }

        XCTAssertEqual(interrupts[0].epoch, 1)
        XCTAssertEqual(interrupts[1].epoch, 2)
        await hub.unsubscribe(subID)
    }
}
```

- [ ] **Step 2: Delete AgentBridgeActor before writing CognitiveCoreActor (avoids `AgentLLMProvider` name collision)**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti
rm Banti/Core/AgentBridgeActor.swift
rm BantiTests/AgentBridgeActorTests.swift
```

- [ ] **Step 3: Regen and verify tests fail**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti && xcodegen generate
xcodebuild test -project Banti.xcodeproj -scheme Banti \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BantiTests/CognitiveCoreActorTests \
  2>&1 | grep "error:" | head -5
```
Expected: compile errors — `CognitiveCoreActor`, `AgentLLMProvider`, `AgentStreamEvent`, `CachedPromptBlock` not found.

- [ ] **Step 4: Implement CognitiveCoreActor**

```swift
// Banti/Banti/Core/CognitiveCoreActor.swift
import Foundation
import os

// MARK: - Protocol types

enum AgentStreamEvent: Sendable {
    case speakChunk(String)
    case speakDone
    case silent
    case error(Error)
}

struct CachedPromptBlock: Sendable {
    let text: String
    let cached: Bool
}

protocol AgentLLMProvider: Sendable {
    func streamResponse(
        systemPrompt: CachedPromptBlock,
        olderContext: CachedPromptBlock,
        recentContext: String,
        triggerSource: String
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

// MARK: - Real Claude provider

struct ClaudeAgentProvider: AgentLLMProvider {
    let apiKey: String
    let model: String

    static let defaultModel = "claude-haiku-4-5-20251001"

    private static let systemPromptText = """
        You are banti, an ambient AI assistant running on the user's Mac. \
        You observe their environment continuously through camera, screen, microphone, and \
        accessibility data. You decide whether to speak based on the perception log provided. \
        Only speak when you have something genuinely useful to say — silence is always valid. \
        Keep responses brief: 1–2 sentences. No preamble.
        """

    func streamResponse(
        systemPrompt: CachedPromptBlock,
        olderContext: CachedPromptBlock,
        recentContext: String,
        triggerSource: String
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = URL(string: "https://api.anthropic.com/v1/messages")!
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    func block(_ b: CachedPromptBlock) -> [String: Any] {
                        var d: [String: Any] = ["type": "text", "text": b.text]
                        if b.cached { d["cache_control"] = ["type": "ephemeral"] }
                        return d
                    }

                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "max_tokens": 256,
                        "system": [block(systemPrompt)],
                        "messages": [[
                            "role": "user",
                            "content": [
                                block(olderContext),
                                ["type": "text", "text": recentContext + "\nTrigger: \(triggerSource)"]
                            ]
                        ]],
                        "tools": [[
                            "name": "speak",
                            "description": "Say something to the user. Only call this if there is something genuinely useful to say. Stay silent by not calling this tool.",
                            "input_schema": [
                                "type": "object",
                                "properties": ["text": ["type": "string", "description": "What to say. 1-2 sentences."]],
                                "required": ["text"]
                            ]
                        ]],
                        "tool_choice": ["type": "auto"]
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.finish(throwing: CognitiveCoreError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"))
                        return
                    }

                    // SSE parsing state
                    var toolCallSeen = false
                    var extractingText = false
                    var escapeNext = false
                    var partialBuf = ""

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]" else { break }
                        guard let data = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        switch json["type"] as? String ?? "" {
                        case "content_block_start":
                            if let block = json["content_block"] as? [String: Any],
                               block["type"] as? String == "tool_use",
                               block["name"] as? String == "speak" {
                                toolCallSeen = true
                                extractingText = false
                                escapeNext = false
                                partialBuf = ""
                            }
                        case "content_block_delta":
                            guard toolCallSeen,
                                  let delta = json["delta"] as? [String: Any],
                                  delta["type"] as? String == "input_json_delta",
                                  let partial = delta["partial_json"] as? String
                            else { continue }

                            if !extractingText {
                                partialBuf += partial
                                if let range = partialBuf.range(of: #""text":""#) {
                                    extractingText = true
                                    let remainder = String(partialBuf[range.upperBound...])
                                    partialBuf = ""
                                    let extracted = extractUntilQuote(remainder, escapeNext: &escapeNext)
                                    if !extracted.isEmpty { continuation.yield(.speakChunk(extracted)) }
                                }
                            } else {
                                let extracted = extractUntilQuote(partial, escapeNext: &escapeNext)
                                if !extracted.isEmpty { continuation.yield(.speakChunk(extracted)) }
                            }

                        case "content_block_stop":
                            if toolCallSeen { continuation.yield(.speakDone); toolCallSeen = false }

                        case "message_delta":
                            if let delta = json["delta"] as? [String: Any],
                               delta["stop_reason"] as? String == "end_turn",
                               !toolCallSeen {
                                continuation.yield(.silent)
                            }
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() }
                    else { continuation.finish(throwing: error) }
                }
            }
        }
    }

    /// Extracts characters from `s` until an unescaped closing `"`, updating escape state.
    private func extractUntilQuote(_ s: String, escapeNext: inout Bool) -> String {
        var result = ""
        for c in s {
            if escapeNext {
                switch c {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(c)
                }
                escapeNext = false
            } else if c == "\\" {
                escapeNext = true
            } else if c == "\"" {
                break
            } else {
                result.append(c)
            }
        }
        return result
    }
}

struct CognitiveCoreError: Error, LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

// MARK: - Actor

actor CognitiveCoreActor: BantiModule {
    nonisolated let id = ModuleID("cognitive-core")
    nonisolated let capabilities: Set<Capability> = []

    private let eventHub: EventHubActor
    private let perceptionLog: PerceptionLogActor
    private var subscriptionIDs: [SubscriptionID] = []
    private var _health: ModuleHealth = .healthy
    private let logger = Logger(subsystem: "com.banti.cognitive", category: "Core")

    // Provider — optional to support config-based lazy init
    private var provider: (any AgentLLMProvider)?
    private let config: ConfigActor?

    // Epoch — single source of truth
    private var epoch: Int = 0
    private var streamTask: Task<Void, Never>?
    private var sentenceBuffer: String = ""
    private var pendingTurnText: String = ""

    // Trigger debounce
    private var lastScreenTrigger: Date = .distantPast
    private var lastSceneTrigger: Date = .distantPast
    private var lastAppTrigger: Date = .distantPast

    private let screenInterval: TimeInterval
    private let sceneInterval: TimeInterval
    private let appInterval: TimeInterval
    private let screenThreshold: Float
    private let sceneThreshold: Float

    /// Inject provider directly — used by tests.
    init(eventHub: EventHubActor,
         perceptionLog: PerceptionLogActor,
         provider: any AgentLLMProvider,
         screenInterval: TimeInterval = 5,
         sceneInterval: TimeInterval = 10,
         appInterval: TimeInterval = 5,
         screenThreshold: Float = 0.3,
         sceneThreshold: Float = 0.3) {
        self.eventHub = eventHub
        self.perceptionLog = perceptionLog
        self.provider = provider
        self.config = nil
        self.screenInterval = screenInterval
        self.sceneInterval = sceneInterval
        self.appInterval = appInterval
        self.screenThreshold = screenThreshold
        self.sceneThreshold = sceneThreshold
    }

    /// Read API key from config at start() — used by BantiApp.
    init(eventHub: EventHubActor,
         perceptionLog: PerceptionLogActor,
         config: ConfigActor,
         screenInterval: TimeInterval = 5,
         sceneInterval: TimeInterval = 10,
         appInterval: TimeInterval = 5,
         screenThreshold: Float = 0.3,
         sceneThreshold: Float = 0.3) {
        self.eventHub = eventHub
        self.perceptionLog = perceptionLog
        self.provider = nil
        self.config = config
        self.screenInterval = screenInterval
        self.sceneInterval = sceneInterval
        self.appInterval = appInterval
        self.screenThreshold = screenThreshold
        self.sceneThreshold = sceneThreshold
    }

    func start() async throws {
        // Resolve provider from config if not injected
        if provider == nil, let cfg = config {
            let apiKey = try await cfg.require(EnvKey.anthropicAPIKey)
            let model = await cfg.value(for: EnvKey.claudeModel) ?? ClaudeAgentProvider.defaultModel
            provider = ClaudeAgentProvider(apiKey: apiKey, model: model)
        }
        guard provider != nil else { throw CognitiveCoreError("No LLM provider configured") }

        subscriptionIDs.append(await eventHub.subscribe(TurnEndedEvent.self)       { [weak self] e in await self?.handleTurnEnded(e) })
        subscriptionIDs.append(await eventHub.subscribe(TurnStartedEvent.self)     { [weak self] e in await self?.handleTurnStarted(e) })
        subscriptionIDs.append(await eventHub.subscribe(ScreenDescriptionEvent.self) { [weak self] e in await self?.handleScreenDesc(e) })
        subscriptionIDs.append(await eventHub.subscribe(SceneDescriptionEvent.self)  { [weak self] e in await self?.handleSceneDesc(e) })
        subscriptionIDs.append(await eventHub.subscribe(ActiveAppEvent.self)         { [weak self] e in await self?.handleAppSwitch(e) })
        _health = .healthy
    }

    func stop() async {
        streamTask?.cancel()
        streamTask = nil
        for s in subscriptionIDs { await eventHub.unsubscribe(s) }
        subscriptionIDs.removeAll()
    }

    func health() async -> ModuleHealth { _health }

    // MARK: - Trigger handlers

    private func handleTurnEnded(_ event: TurnEndedEvent) {
        pendingTurnText = event.text
        launchStream(triggerSource: "user_speech")
    }

    private func handleTurnStarted(_ event: TurnStartedEvent) {
        streamTask?.cancel()
        streamTask = nil
        sentenceBuffer = ""
        epoch += 1
        let e = epoch
        Task { await eventHub.publish(InterruptEvent(epoch: e)) }
    }

    private func handleScreenDesc(_ event: ScreenDescriptionEvent) {
        guard let dist = event.changeDistance, dist >= screenThreshold else { return }
        let now = Date()
        guard now.timeIntervalSince(lastScreenTrigger) >= screenInterval else { return }
        lastScreenTrigger = now
        launchStream(triggerSource: "screen_change")
    }

    private func handleSceneDesc(_ event: SceneDescriptionEvent) {
        guard event.changeDistance >= sceneThreshold else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSceneTrigger) >= sceneInterval else { return }
        lastSceneTrigger = now
        launchStream(triggerSource: "scene_change")
    }

    private func handleAppSwitch(_ event: ActiveAppEvent) {
        let now = Date()
        guard now.timeIntervalSince(lastAppTrigger) >= appInterval else { return }
        lastAppTrigger = now
        launchStream(triggerSource: "app_switch")
    }

    // MARK: - Streaming

    private func launchStream(triggerSource: String) {
        guard let prov = provider else {
            _health = .degraded(reason: "No LLM provider configured")
            return
        }
        streamTask?.cancel()
        sentenceBuffer = ""  // clear any partial sentence from the preempted stream
        let currentEpoch = epoch
        let capturedTurnText = pendingTurnText
        let log = perceptionLog.log()
        let stream = prov.streamResponse(
            systemPrompt: CachedPromptBlock(text: ClaudeAgentProvider.systemPromptText, cached: true),
            olderContext: CachedPromptBlock(text: log.formattedOlder(), cached: true),
            recentContext: log.formattedRecent(),
            triggerSource: triggerSource
        )
        streamTask = Task {
            await runStream(stream: stream, triggerSource: triggerSource,
                            epoch: currentEpoch, turnText: capturedTurnText)
        }
    }

    private func runStream(
        stream: AsyncThrowingStream<AgentStreamEvent, Error>,
        triggerSource: String,
        epoch: Int,
        turnText: String
    ) async {
        var accumulated = ""
        do {
            for try await event in stream {
                guard !Task.isCancelled else { return }
                switch event {
                case .speakChunk(let text):
                    sentenceBuffer += text
                    accumulated += text
                    if sentenceBuffer.count >= 15,
                       let last = sentenceBuffer.last,
                       ".!?".contains(last) {
                        let chunk = sentenceBuffer.trimmingCharacters(in: .whitespaces)
                        sentenceBuffer = ""
                        await eventHub.publish(SpeakChunkEvent(text: chunk, epoch: epoch))
                    }
                case .speakDone:
                    if !sentenceBuffer.isEmpty {
                        let chunk = sentenceBuffer.trimmingCharacters(in: .whitespaces)
                        sentenceBuffer = ""
                        await eventHub.publish(SpeakChunkEvent(text: chunk, epoch: epoch))
                    }
                    let userText = triggerSource == "user_speech" ? turnText : ""
                    await eventHub.publish(AgentResponseEvent(
                        userText: userText,
                        responseText: accumulated,
                        sourceModule: id))
                case .silent:
                    return
                case .error(let err):
                    logger.error("LLM stream error: \(err.localizedDescription, privacy: .public)")
                    _health = .degraded(reason: err.localizedDescription)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Stream threw: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - PerceptionLog formatting helpers

extension PerceptionLog {
    func formattedOlder() -> String {
        let now = Date()
        let cutoff = now.addingTimeInterval(-recentWindowSeconds)
        let older = entries.filter { $0.timestamp < cutoff }
        guard !older.isEmpty else { return "(no older context)" }
        return "=== Perception Log — Older (>\(Int(recentWindowSeconds))s) ===\n" +
            older.map { formatEntry($0, now: now) }.joined(separator: "\n")
    }

    func formattedRecent() -> String {
        let now = Date()
        let cutoff = now.addingTimeInterval(-recentWindowSeconds)
        let recent = entries.filter { $0.timestamp >= cutoff }
        var lines: [String] = []
        if !recent.isEmpty {
            lines.append("=== Perception Log — Recent (<\(Int(recentWindowSeconds))s) ===")
            lines.append(contentsOf: recent.map { formatEntry($0, now: now) })
        }
        lines.append("=== Active Now ===")
        if let app = activeApp { lines.append("App: \(app.appName) (\(app.bundleIdentifier))") }
        if let ax = axFocus {
            var l = "Focus: \(ax.elementRole)"
            if let t = ax.elementTitle { l += " — \(t)" }
            lines.append(l)
        }
        return lines.joined(separator: "\n")
    }

    private func formatEntry(_ e: PerceptionLogEntry, now: Date) -> String {
        let age = max(0, Int(now.timeIntervalSince(e.timestamp)))
        let k: String
        switch e.kind {
        case .screenDescription: k = "SCREEN    "
        case .sceneDescription:  k = "SCENE     "
        case .transcript:        k = "TRANSCRIPT"
        case .appSwitch:         k = "APP       "
        case .axFocus:           k = "AX_FOCUS  "
        }
        var line = "[\(String(format: "%3d", age))s ago] \(k)"
        if let d = e.changeDistance { line += " dist=\(String(format: "%.2f", d))" }
        return line + " | \(e.summary)"
    }
}

// Make system prompt accessible from ClaudeAgentProvider
extension ClaudeAgentProvider {
    static var systemPromptText: String {
        """
        You are banti, an ambient AI assistant running on the user's Mac. \
        You observe their environment continuously. Decide whether to speak \
        based on the perception log. Only speak when genuinely useful — \
        silence is always valid. Keep responses brief: 1–2 sentences.
        """
    }
}
```

- [ ] **Step 5: Regen and run tests**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti && xcodegen generate
xcodebuild test -project Banti.xcodeproj -scheme Banti \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BantiTests/CognitiveCoreActorTests \
  2>&1 | grep -E "(Test Case|error:|passed|failed)" | tail -30
```
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Banti/Banti/Core/CognitiveCoreActor.swift \
        Banti/BantiTests/CognitiveCoreActorTests.swift
git commit -m "feat: add CognitiveCoreActor with streaming tool-use FLAG, debounce, barge-in"
```

---

## Task 4: StreamingTTSActor (TDD)

**Files:**
- Create: `Banti/BantiTests/StreamingTTSActorTests.swift`
- Create: `Banti/Banti/Core/StreamingTTSActor.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Banti/BantiTests/StreamingTTSActorTests.swift
import XCTest
@testable import Banti

// MARK: - Stub

actor StubCartesiaWSProvider: CartesiaWebSocketProvider {
    struct SendCall { let text: String; let contextID: String; let continuing: Bool }
    private(set) var sendCalls: [SendCall] = []
    private(set) var disconnected = false
    private(set) var connectCount = 0
    var shouldThrowOnConnect = false

    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    func connect() async throws -> AsyncThrowingStream<Data, Error> {
        if shouldThrowOnConnect { throw URLError(.cannotConnectToHost) }
        connectCount += 1
        // Use makeStream() so the continuation is captured synchronously — no weak-self race.
        let (stream, cont) = AsyncThrowingStream.makeStream(of: Data.self)
        continuation = cont
        return stream
    }

    func send(text: String, contextID: String, continuing: Bool) async throws {
        sendCalls.append(SendCall(text: text, contextID: contextID, continuing: continuing))
    }

    func disconnect() async {
        disconnected = true
        continuation?.finish()
    }

    func simulateAudioChunk(_ data: Data) {
        continuation?.yield(data)
    }
}

// MARK: - Tests

final class StreamingTTSActorTests: XCTestCase {

    func waitUntil(_ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while await !condition() {
            guard Date() < deadline else { return }
            await Task.yield()
        }
    }

    func makeChunk(text: String = "Hello world.", epoch: Int = 0) -> SpeakChunkEvent {
        SpeakChunkEvent(text: text, epoch: epoch)
    }

    func makeInterrupt(epoch: Int) -> InterruptEvent {
        InterruptEvent(epoch: epoch)
    }

    // MARK: - Basic forwarding

    func testChunkForwardedToCartesia() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub)
        try await tts.start()

        await hub.publish(makeChunk(text: "Hello.", epoch: 0))
        await waitUntil { await stub.sendCalls.count == 1 }

        let call = await stub.sendCalls[0]
        XCTAssertEqual(call.text, "Hello.")
        XCTAssertTrue(call.continuing)
    }

    // MARK: - Epoch gate

    func testStaleChunkDiscarded() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub)
        try await tts.start()

        // Interrupt advances epoch to 1
        await hub.publish(makeInterrupt(epoch: 1))
        try await Task.sleep(for: .milliseconds(50))

        // Publish chunk with old epoch 0 — should be discarded
        await hub.publish(makeChunk(text: "stale", epoch: 0))
        try await Task.sleep(for: .milliseconds(200))

        let calls = await stub.sendCalls
        let flushed = calls.filter { !$0.continuing }
        XCTAssertEqual(flushed.count, 1, "Interrupt should send continue:false")
        XCTAssertFalse(calls.contains { $0.text == "stale" }, "Stale chunk should not be sent")
    }

    func testCurrentEpochChunkForwarded() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub)
        try await tts.start()

        await hub.publish(makeInterrupt(epoch: 1))
        try await Task.sleep(for: .milliseconds(50))

        await hub.publish(makeChunk(text: "fresh", epoch: 1))
        await waitUntil { await stub.sendCalls.filter({ $0.text == "fresh" }).count == 1 }

        let calls = await stub.sendCalls
        XCTAssertTrue(calls.contains { $0.text == "fresh" })
    }

    // MARK: - context_id consistency

    func testChunksForSameUtteranceShareContextID() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub)
        try await tts.start()

        await hub.publish(makeChunk(text: "First.", epoch: 0))
        await hub.publish(makeChunk(text: "Second.", epoch: 0))
        await waitUntil { await stub.sendCalls.count == 2 }

        let calls = await stub.sendCalls
        XCTAssertEqual(calls[0].contextID, calls[1].contextID, "Same utterance must share contextID")
        XCTAssertFalse(calls[0].contextID.isEmpty)
    }

    func testNewContextIDAfterInterrupt() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub)
        try await tts.start()

        await hub.publish(makeChunk(text: "Before.", epoch: 0))
        await waitUntil { await stub.sendCalls.count == 1 }
        let firstID = await stub.sendCalls[0].contextID

        await hub.publish(makeInterrupt(epoch: 1))
        try await Task.sleep(for: .milliseconds(50))

        await hub.publish(makeChunk(text: "After.", epoch: 1))
        await waitUntil { await stub.sendCalls.filter({ $0.continuing && $0.text == "After." }).count == 1 }

        let afterCall = await stub.sendCalls.first { $0.text == "After." }
        XCTAssertNotEqual(afterCall?.contextID, firstID, "New utterance needs a new contextID")
    }

    // MARK: - Interrupt sends continue:false

    func testInterruptSendsContinueFalse() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub)
        try await tts.start()

        await hub.publish(makeChunk(text: "Hello.", epoch: 0))
        await waitUntil { await stub.sendCalls.count == 1 }
        let contextID = await stub.sendCalls[0].contextID

        await hub.publish(makeInterrupt(epoch: 1))
        await waitUntil { await stub.sendCalls.contains { !$0.continuing } }

        let flushCall = await stub.sendCalls.first { !$0.continuing }
        XCTAssertEqual(flushCall?.contextID, contextID)
        XCTAssertEqual(flushCall?.text, "")
    }

    // MARK: - Health degrades on connect failure

    func testHealthDegradedOnConnectFailure() async throws {
        let hub = EventHubActor()
        let stub = StubCartesiaWSProvider()
        stub.shouldThrowOnConnect = true
        let tts = StreamingTTSActor(eventHub: hub, wsProvider: stub,
                                    reconnectBaseDelay: 0.01, maxReconnectDelay: 0.05)
        try await tts.start()

        // Trigger a chunk to force a connect attempt
        await hub.publish(makeChunk(text: "Hello.", epoch: 0))

        await waitUntil {
            let h = await tts.health()
            if case .degraded = h { return true }
            return false
        }

        if case .degraded = await tts.health() { /* expected */ }
        else { XCTFail("Expected .degraded after connect failure") }
    }
}
```

- [ ] **Step 2: Regen and verify tests fail**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti && xcodegen generate
xcodebuild test -project Banti.xcodeproj -scheme Banti \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BantiTests/StreamingTTSActorTests \
  2>&1 | grep "error:" | head -5
```
Expected: compile errors — `CartesiaWebSocketProvider`, `StreamingTTSActor` not found.

- [ ] **Step 3: Implement StreamingTTSActor**

```swift
// Banti/Banti/Core/StreamingTTSActor.swift
import Foundation
import AVFoundation
import os

// MARK: - Protocol

protocol CartesiaWebSocketProvider: Sendable {
    func connect() async throws -> AsyncThrowingStream<Data, Error>
    func send(text: String, contextID: String, continuing: Bool) async throws
    func disconnect() async
}

// MARK: - Real provider
// Must be an actor (not struct) so wsTask is shared between connect() and send().

actor RealCartesiaWSProvider: CartesiaWebSocketProvider {
    let apiKey: String
    let voiceID: String
    let cartesiaVersion: String

    static let defaultVoiceID = "694f9389-aac1-45b6-b726-9d9369183238"
    private static let modelID = "sonic-3"

    private var wsTask: URLSessionWebSocketTask?

    init(apiKey: String, voiceID: String = RealCartesiaWSProvider.defaultVoiceID,
         cartesiaVersion: String) {
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.cartesiaVersion = cartesiaVersion
    }

    private func makeURL() -> URL {
        URL(string: "wss://api.cartesia.ai/tts/websocket?api_key=\(apiKey)&cartesia_version=\(cartesiaVersion)")!
    }

    func connect() async throws -> AsyncThrowingStream<Data, Error> {
        let task = URLSession.shared.webSocketTask(with: makeURL())
        task.resume()
        wsTask = task  // store so send() can use the same task

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    while true {
                        let msg = try await task.receive()
                        switch msg {
                        case .string(let s):
                            guard let data = s.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                            else { continue }
                            let type_ = json["type"] as? String ?? ""
                            if type_ == "chunk", let b64 = json["data"] as? String,
                               let pcm = Data(base64Encoded: b64) {
                                continuation.yield(pcm)
                            } else if type_ == "done" {
                                // utterance complete — keep connection open for next chunk
                            }
                        case .data: break
                        @unknown default: break
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func send(text: String, contextID: String, continuing: Bool) async throws {
        guard let task = wsTask else { throw URLError(.notConnectedToInternet) }
        let payload: [String: Any] = [
            "context_id": contextID,
            "model_id": Self.modelID,
            "transcript": text,
            "voice": ["mode": "id", "id": voiceID],
            "output_format": ["container": "raw", "encoding": "pcm_f32le", "sample_rate": 44100],
            "continue": continuing,
            "add_timestamps": false
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await task.send(.string(String(data: data, encoding: .utf8)!))
    }

    func disconnect() async {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }
}

// MARK: - Actor

actor StreamingTTSActor: BantiModule {
    nonisolated let id = ModuleID("streaming-tts")
    nonisolated let capabilities: Set<Capability> = [.speech]

    private let eventHub: EventHubActor
    private var wsProvider: any CartesiaWebSocketProvider  // var so start() can inject real API key
    private let config: ConfigActor?
    private var subscriptionIDs: [SubscriptionID] = []
    private var _health: ModuleHealth = .healthy
    private let logger = Logger(subsystem: "com.banti.tts", category: "Streaming")

    // Epoch — SET from InterruptEvent.epoch (never incremented here)
    private var epoch: Int = 0

    // Current utterance context
    private var currentContextID: String?

    // Task that owns the WebSocket audio loop; cancelled in stop()
    private var connectTask: Task<Void, Never>?

    // Audio engine
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    // 44100 Hz matches the Cartesia output_format sample_rate in RealCartesiaWSProvider.send()
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 44100, channels: 1, interleaved: false)!

    // Reconnect config
    private let reconnectBaseDelay: TimeInterval
    private let maxReconnectDelay: TimeInterval

    init(eventHub: EventHubActor,
         wsProvider: any CartesiaWebSocketProvider,
         reconnectBaseDelay: TimeInterval = 1.0,
         maxReconnectDelay: TimeInterval = 30.0) {
        self.eventHub = eventHub
        self.wsProvider = wsProvider
        self.config = nil
        self.reconnectBaseDelay = reconnectBaseDelay
        self.maxReconnectDelay = maxReconnectDelay
    }

    init(eventHub: EventHubActor, config: ConfigActor,
         reconnectBaseDelay: TimeInterval = 1.0,
         maxReconnectDelay: TimeInterval = 30.0) {
        self.eventHub = eventHub
        self.wsProvider = RealCartesiaWSProvider(
            apiKey: "", voiceID: RealCartesiaWSProvider.defaultVoiceID,
            cartesiaVersion: "2025-04-16") // real key injected at start()
        self.config = config
        self.reconnectBaseDelay = reconnectBaseDelay
        self.maxReconnectDelay = maxReconnectDelay
    }

    func start() async throws {
        // Inject real Cartesia API key from config
        if let cfg = config {
            let apiKey = try await cfg.require(EnvKey.cartesiaAPIKey)
            wsProvider = RealCartesiaWSProvider(apiKey: apiKey,
                                                voiceID: RealCartesiaWSProvider.defaultVoiceID,
                                                cartesiaVersion: "2025-04-16")
        }

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
        try audioEngine.start()

        subscriptionIDs.append(await eventHub.subscribe(SpeakChunkEvent.self) { [weak self] e in
            await self?.handle(e)
        })
        subscriptionIDs.append(await eventHub.subscribe(InterruptEvent.self) { [weak self] e in
            await self?.handle(e)
        })

        // Connect to Cartesia and begin streaming PCM audio
        connectTask = Task { await connectAndListen() }
        _health = .healthy
    }

    // MARK: - WebSocket audio loop

    /// Connects to Cartesia and drains PCM audio chunks into scheduleAudio.
    /// On failure sets health degraded and returns — handleDisconnect() handles retry.
    private func connectAndListen() async {
        do {
            let stream = try await wsProvider.connect()
            _health = .healthy
            for try await pcmData in stream {
                scheduleAudio(pcmData, epoch: self.epoch)
            }
        } catch {
            guard !Task.isCancelled else { return }
            _health = .degraded(reason: "Cartesia WebSocket: \(error.localizedDescription)")
            currentContextID = nil
        }
    }

    func stop() async {
        connectTask?.cancel()
        connectTask = nil
        for s in subscriptionIDs { await eventHub.unsubscribe(s) }
        subscriptionIDs.removeAll()
        playerNode.stop()
        audioEngine.stop()
        await wsProvider.disconnect()
    }

    func health() async -> ModuleHealth { _health }

    // MARK: - Event handlers

    private func handle(_ event: SpeakChunkEvent) async {
        guard event.epoch == self.epoch else { return }

        if currentContextID == nil {
            currentContextID = UUID().uuidString
        }
        guard let ctxID = currentContextID else { return }

        do {
            try await wsProvider.send(text: event.text, contextID: ctxID, continuing: true)
        } catch {
            logger.warning("Cartesia send failed: \(error.localizedDescription, privacy: .public)")
            await handleDisconnect()
        }
    }

    private func handle(_ event: InterruptEvent) async {
        // SET epoch from the authoritative source (CognitiveCoreActor)
        self.epoch = event.epoch

        // Flush Cartesia context
        if let ctxID = currentContextID {
            try? await wsProvider.send(text: "", contextID: ctxID, continuing: false)
            currentContextID = nil
        }

        // Stop audio
        playerNode.stop()
    }

    // MARK: - Audio scheduling (called when Cartesia sends PCM back)

    private func scheduleAudio(_ pcmData: Data, epoch: Int) {
        guard epoch == self.epoch else { return }
        guard let buffer = pcmData.toAVAudioPCMBuffer(format: audioFormat) else { return }
        playerNode.scheduleBuffer(buffer)
        if !playerNode.isPlaying { playerNode.play() }
    }

    // MARK: - Reconnect

    private func handleDisconnect() async {
        _health = .degraded(reason: "Cartesia WebSocket disconnected")
        currentContextID = nil

        var delay = reconnectBaseDelay
        while true {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            do {
                let stream = try await wsProvider.connect()
                _health = .healthy
                logger.notice("Cartesia reconnected")
                for try await pcmData in stream {
                    scheduleAudio(pcmData, epoch: self.epoch)
                }
                return // stream closed cleanly
            } catch {
                delay = min(delay * 2, maxReconnectDelay)
                logger.warning("Cartesia reconnect failed, retry in \(delay)s")
            }
        }
    }
}

// MARK: - Data → AVAudioPCMBuffer

private extension Data {
    func toAVAudioPCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(count / MemoryLayout<Float32>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount
        self.withUnsafeBytes { ptr in
            if let src = ptr.bindMemory(to: Float32.self).baseAddress,
               let dst = buffer.floatChannelData?[0] {
                dst.update(from: src, count: Int(frameCount))
            }
        }
        return buffer
    }
}
```

- [ ] **Step 4: Regen and run tests**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti && xcodegen generate
xcodebuild test -project Banti.xcodeproj -scheme Banti \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BantiTests/StreamingTTSActorTests \
  2>&1 | grep -E "(Test Case|error:|passed|failed)" | tail -20
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Banti/Banti/Core/StreamingTTSActor.swift \
        Banti/BantiTests/StreamingTTSActorTests.swift
git commit -m "feat: add StreamingTTSActor with Cartesia WebSocket streaming and epoch-based barge-in"
```

---

## Task 5: Bootstrap Wiring + EventLogger Update + Cleanup

**Files:**
- Modify: `Banti/Banti/BantiApp.swift`
- Modify: `Banti/Banti/Core/EventLoggerActor.swift`
- Delete: old actor/test files

- [ ] **Step 1: Add SpeakChunkEvent and InterruptEvent logging to EventLoggerActor**

In `EventLoggerActor.start()`, add two new subscriptions after the existing ones:

```swift
subscriptionIDs.append(await eventHub.subscribe(SpeakChunkEvent.self) { [weak self] event in
    guard let self else { return }
    await self.logSpeakChunk(event)
})
subscriptionIDs.append(await eventHub.subscribe(InterruptEvent.self) { [weak self] event in
    guard let self else { return }
    await self.logInterrupt(event)
})
```

Add the two private methods:
```swift
private func logSpeakChunk(_ event: SpeakChunkEvent) {
    logger.notice("SpeakChunk epoch=\(event.epoch) text=\(String(event.text.prefix(60)), privacy: .public)")
}

private func logInterrupt(_ event: InterruptEvent) {
    logger.notice("Interrupt epoch=\(event.epoch)")
}
```

Update the count in the start log message from 10 to 12.

- [ ] **Step 2: Rewrite BantiApp bootstrap**

Replace the cognitive pipeline section in `BantiApp.init()` and `bootstrap()`. The changes:

1. In `init()`: replace `contextSnapshot`, `agentBridge`, `tts` with `perceptionLog`, `cognitiveCore`, `streamingTTS`:

```swift
// Remove:
private let contextSnapshot: ContextSnapshotActor
private let agentBridge: AgentBridgeActor
private let tts: TTSActor

// Add:
private let perceptionLog: PerceptionLogActor
private let cognitiveCore: CognitiveCoreActor
private let streamingTTS: StreamingTTSActor
```

2. In `init()` body: replace the construction of the three old actors:

```swift
// Remove:
let contextSnapshotActor = ContextSnapshotActor(eventHub: hub)
let agentBridgeActor = AgentBridgeActor(eventHub: hub, contextSnapshot: contextSnapshotActor, config: cfg)
let ttsActor = TTSActor(eventHub: hub, config: cfg)

// Add:
let perceptionLogActor = PerceptionLogActor(eventHub: hub)
// Use config-based init — ClaudeAgentProvider is created inside start() once the API key is available.
let cognitiveCoreActor = CognitiveCoreActor(eventHub: hub, perceptionLog: perceptionLogActor,
                                            config: cfg)
let streamingTTSActor = StreamingTTSActor(eventHub: hub, config: cfg)
```

Then in `CognitiveCoreActor.start()`, add the key-read logic:
```swift
if provider == nil, let cfg = config {
    let apiKey = try await cfg.require(EnvKey.anthropicAPIKey)
    let model = await cfg.value(for: EnvKey.claudeModel) ?? ClaudeAgentProvider.defaultModel
    provider = ClaudeAgentProvider(apiKey: apiKey, model: model)
}
```

4. In `bootstrap()`: replace old actor registrations with new ones:

```swift
// Remove:
await sup.register(contextSnapshot, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
await sup.register(agentBridge, restartPolicy: .onFailure(maxRetries: 3, backoff: 2),
                   dependencies: [contextSnapshot.id, turnDetector.id])
await sup.register(memoryWriteBack, restartPolicy: .onFailure(maxRetries: 3, backoff: 1),
                   dependencies: [agentBridge.id])
await sup.register(tts, restartPolicy: .onFailure(maxRetries: 3, backoff: 1),
                   dependencies: [agentBridge.id])

// Add:
await sup.register(perceptionLog, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
await sup.register(cognitiveCore, restartPolicy: .onFailure(maxRetries: 3, backoff: 2),
                   dependencies: [perceptionLog.id, turnDetector.id])
await sup.register(memoryWriteBack, restartPolicy: .onFailure(maxRetries: 3, backoff: 1),
                   dependencies: [cognitiveCore.id])
await sup.register(streamingTTS, restartPolicy: .onFailure(maxRetries: 3, backoff: 1),
                   dependencies: [cognitiveCore.id])
```

- [ ] **Step 3: Regen and verify build**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti && xcodegen generate
xcodebuild build -project Banti.xcodeproj -scheme Banti \
  -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E "(error:|BUILD)" | tail -10
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Run full test suite**

```bash
xcodebuild test -project Banti.xcodeproj -scheme Banti \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E "(Test Suite|error:|passed|failed)" | tail -20
```
Expected: all tests pass.

- [ ] **Step 5: Delete old files**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti
rm Banti/Core/ContextSnapshotActor.swift
rm Banti/Core/AgentBridgeActor.swift
rm Banti/Core/TTSActor.swift
rm BantiTests/ContextSnapshotActorTests.swift
rm BantiTests/AgentBridgeActorTests.swift
rm BantiTests/TTSActorTests.swift
```

- [ ] **Step 6: Regen and verify full suite still passes**

```bash
xcodegen generate
xcodebuild test -project Banti.xcodeproj -scheme Banti \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E "(Test Suite|passed|failed)" | tail -5
```
Expected: all remaining tests pass, no compile errors.

- [ ] **Step 7: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add -A
git commit -m "feat: wire proactive cognitive pipeline — PerceptionLogActor, CognitiveCoreActor, StreamingTTSActor"
```
