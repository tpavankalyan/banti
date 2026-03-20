# Cortical Graph — Phase 1: Infrastructure

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce EventBus, BantiEvent types, CorticalNode protocol, BantiClock, and ContextAggregator — adapting existing components to publish/subscribe via the bus without changing any observable behaviour.

**Architecture:** A shared `actor EventBus` replaces direct method calls. Existing actors (`PerceptionRouter`, `AudioRouter`, `BantiVoice`) gain bus publishing as a parallel side-channel while keeping all current logic intact. All 190 existing tests must continue to pass at the end of this phase.

**Tech Stack:** Swift structured concurrency, Swift actors, `mach_timebase_info`, XCTest

---

## File Map

**New files:**
- `Sources/BantiCore/BantiClock.swift` — nanosecond clock utility
- `Sources/BantiCore/BantiEvent.swift` — `BantiEvent` struct, `EventPayload` enum, all payload types
- `Sources/BantiCore/EventBus.swift` — `EventBus` actor + `SubscriptionID`
- `Sources/BantiCore/CorticalNode.swift` — `CorticalNode` protocol
- `Sources/BantiCore/ContextAggregator.swift` — aggregates `sensor.*` events, provides `snapshotJSON()`

**Modified files:**
- `Sources/BantiCore/PerceptionRouter.swift` — accept optional `EventBus`; publish face/emotion/activity/gesture/screen events at end of `dispatch()`
- `Sources/BantiCore/AudioRouter.swift` — accept optional `EventBus`; publish `sensor.audio` on transcript and Hume events
- `Sources/BantiCore/BantiVoice.swift` — accept optional `EventBus`; publish `motor.voice` on speak start/end
- `Sources/BantiCore/MemoryEngine.swift` — create `EventBus`; pass to `PerceptionRouter`, `AudioRouter`, `BantiVoice`
- `Sources/banti/main.swift` — no changes needed (EventBus created inside MemoryEngine)

**New test files:**
- `Tests/BantiTests/BantiClockTests.swift`
- `Tests/BantiTests/EventBusTests.swift`
- `Tests/BantiTests/BantiEventTests.swift`
- `Tests/BantiTests/ContextAggregatorTests.swift`

---

## Task 1: BantiClock

**Files:**
- Create: `Sources/BantiCore/BantiClock.swift`
- Create: `Tests/BantiTests/BantiClockTests.swift`

- [ ] **Write the failing test**

```swift
// Tests/BantiTests/BantiClockTests.swift
import XCTest
@testable import BantiCore

final class BantiClockTests: XCTestCase {
    func testNowNsIsMonotonic() {
        let a = BantiClock.nowNs()
        let b = BantiClock.nowNs()
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func testNowNsIsPlausiblyInNanoseconds() {
        // 2020-01-01 in nanoseconds since boot is >> 1e12 on any running system
        // Just verify it's not returning raw ticks (which are typically < 1e11 on M1)
        let ns = BantiClock.nowNs()
        XCTAssertGreaterThan(ns, 0)
    }

    func testNowNsAdvancesByAtLeastOneMicrosecond() throws {
        let a = BantiClock.nowNs()
        Thread.sleep(forTimeInterval: 0.001) // 1ms
        let b = BantiClock.nowNs()
        XCTAssertGreaterThan(b - a, 500_000) // at least 500µs elapsed
    }
}
```

- [ ] **Run test — expect failure** `swift test --filter BantiClockTests 2>&1 | tail -5`

- [ ] **Implement**

```swift
// Sources/BantiCore/BantiClock.swift
import Foundation

public enum BantiClock {
    private static let ratio: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Current time in nanoseconds. Monotonic. Safe to call from any thread.
    public static func nowNs() -> UInt64 {
        mach_absolute_time() * ratio.numer / ratio.denom
    }
}
```

- [ ] **Run test — expect pass** `swift test --filter BantiClockTests 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/BantiClock.swift Tests/BantiTests/BantiClockTests.swift
git commit -m "feat: add BantiClock — nanosecond monotonic clock utility"
```

---

## Task 2: BantiEvent Types

**Files:**
- Create: `Sources/BantiCore/BantiEvent.swift`
- Create: `Tests/BantiTests/BantiEventTests.swift`

- [ ] **Write the failing tests**

```swift
// Tests/BantiTests/BantiEventTests.swift
import XCTest
@testable import BantiCore

final class BantiEventTests: XCTestCase {

    func testSpeechPayloadRoundTrip() throws {
        let payload = SpeechPayload(transcript: "hello world", speakerID: "p1")
        let event = BantiEvent(source: "audio_cortex", topic: "sensor.audio",
                               surprise: 0.8, payload: .speechDetected(payload))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BantiEvent.self, from: data)
        guard case .speechDetected(let p) = decoded.payload else {
            return XCTFail("wrong payload case")
        }
        XCTAssertEqual(p.transcript, "hello world")
        XCTAssertEqual(p.speakerID, "p1")
        XCTAssertEqual(decoded.source, "audio_cortex")
        XCTAssertEqual(decoded.topic, "sensor.audio")
    }

    func testFacePayloadRoundTrip() throws {
        let rect = CodableCGRect(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let payload = FacePayload(boundingBox: rect, personID: "abc", personName: "Alice", confidence: 0.95)
        let event = BantiEvent(source: "visual_cortex", topic: "sensor.visual",
                               surprise: 0.5, payload: .faceUpdate(payload))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BantiEvent.self, from: data)
        guard case .faceUpdate(let p) = decoded.payload else {
            return XCTFail("wrong payload case")
        }
        XCTAssertEqual(p.personName, "Alice")
        XCTAssertEqual(p.confidence, 0.95, accuracy: 0.001)
    }

    func testVoiceSpeakingPayloadRoundTrip() throws {
        let payload = VoiceSpeakingPayload(speaking: true, estimatedDurationMs: 2500,
                                           tailWindowMs: 5000, text: "hey there")
        let event = BantiEvent(source: "banti_voice", topic: "motor.voice",
                               surprise: 0.0, payload: .voiceSpeaking(payload))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(BantiEvent.self, from: data)
        guard case .voiceSpeaking(let p) = decoded.payload else {
            return XCTFail("wrong payload case")
        }
        XCTAssertTrue(p.speaking)
        XCTAssertEqual(p.estimatedDurationMs, 2500)
        XCTAssertEqual(p.text, "hey there")
    }

    func testTimestampIsPopulated() {
        let event = BantiEvent(source: "x", topic: "y", surprise: 0, payload: .speechDetected(SpeechPayload(transcript: "t", speakerID: nil)))
        XCTAssertGreaterThan(event.timestampNs, 0)
    }
}
```

- [ ] **Run test — expect failure** `swift test --filter BantiEventTests 2>&1 | tail -5`

- [ ] **Implement**

```swift
// Sources/BantiCore/BantiEvent.swift
import Foundation

// MARK: - Envelope

public struct BantiEvent: Codable, Sendable {
    public let id: UUID
    public let source: String
    public let topic: String
    public let timestampNs: UInt64
    public let surprise: Float
    public let payload: EventPayload

    public init(source: String, topic: String, surprise: Float, payload: EventPayload) {
        self.id = UUID()
        self.source = source
        self.topic = topic
        self.timestampNs = BantiClock.nowNs()
        self.surprise = surprise
        self.payload = payload
    }
}

// MARK: - Payload enum

public enum EventPayload: Codable, Sendable {
    case speechDetected(SpeechPayload)
    case faceUpdate(FacePayload)
    case screenUpdate(ScreenPayload)
    case emotionUpdate(EmotionPayload)
    case soundUpdate(SoundPayload)
    case episodeBound(EpisodePayload)
    case brainResponse(BrainResponsePayload)
    case brainRoute(BrainRoutePayload)
    case voiceSpeaking(VoiceSpeakingPayload)
    case speechPlan(SpeechPlanPayload)
    case memoryRetrieved(MemoryRetrievedPayload)
    case memorySaved(MemorySavedPayload)
}

// MARK: - Phase 1 payload types (used in this phase)

public struct SpeechPayload: Codable, Sendable {
    public let transcript: String
    public let speakerID: String?
    public init(transcript: String, speakerID: String?) {
        self.transcript = transcript; self.speakerID = speakerID
    }
}

public struct FacePayload: Codable, Sendable {
    public let boundingBox: CodableCGRect
    public let personID: String?
    public let personName: String?
    public let confidence: Float
    public init(boundingBox: CodableCGRect, personID: String?, personName: String?, confidence: Float) {
        self.boundingBox = boundingBox; self.personID = personID
        self.personName = personName; self.confidence = confidence
    }
}

public struct ScreenPayload: Codable, Sendable {
    public let ocrLines: [String]
    public let interpretation: String
    public init(ocrLines: [String], interpretation: String) {
        self.ocrLines = ocrLines; self.interpretation = interpretation
    }
}

public struct EmotionPayload: Codable, Sendable {
    public struct Emotion: Codable, Sendable {
        public let label: String
        public let score: Float
        public init(label: String, score: Float) { self.label = label; self.score = score }
    }
    public let emotions: [Emotion]
    public let source: String  // "hume_face" | "hume_voice"
    public init(emotions: [Emotion], source: String) { self.emotions = emotions; self.source = source }
}

public struct SoundPayload: Codable, Sendable {
    public let label: String
    public let confidence: Float
    public init(label: String, confidence: Float) { self.label = label; self.confidence = confidence }
}

public struct VoiceSpeakingPayload: Codable, Sendable {
    public let speaking: Bool
    public let estimatedDurationMs: Int
    public let tailWindowMs: Int
    public let text: String?
    public init(speaking: Bool, estimatedDurationMs: Int, tailWindowMs: Int, text: String?) {
        self.speaking = speaking; self.estimatedDurationMs = estimatedDurationMs
        self.tailWindowMs = tailWindowMs; self.text = text
    }
}

// MARK: - Phase 2+ payload types (defined now for type stability, used in Phase 2)

public struct EpisodePayload: Codable, Sendable {
    public let episodeID: UUID
    public let text: String
    public let participants: [String]
    public let emotionalTone: String
    public let timestampNs: UInt64
    public init(text: String, participants: [String], emotionalTone: String) {
        self.episodeID = UUID(); self.text = text; self.participants = participants
        self.emotionalTone = emotionalTone; self.timestampNs = BantiClock.nowNs()
    }
}

public struct BrainRoutePayload: Codable, Sendable {
    public let tracks: [String]
    public let reason: String
    public let episode: EpisodePayload
    public init(tracks: [String], reason: String, episode: EpisodePayload) {
        self.tracks = tracks; self.reason = reason; self.episode = episode
    }
}

public struct BrainResponsePayload: Codable, Sendable {
    public let track: String
    public let text: String
    public let activatedTracks: [String]
    public init(track: String, text: String, activatedTracks: [String]) {
        self.track = track; self.text = text; self.activatedTracks = activatedTracks
    }
}

public struct SpeechPlanPayload: Codable, Sendable {
    public let sentences: [String]
    public init(sentences: [String]) { self.sentences = sentences }
}

public struct MemoryRetrievedPayload: Codable, Sendable {
    public let personID: String
    public let personName: String?
    public let facts: [String]
    public let retrievedAtNs: UInt64
    public init(personID: String, personName: String?, facts: [String]) {
        self.personID = personID; self.personName = personName
        self.facts = facts; self.retrievedAtNs = BantiClock.nowNs()
    }
}

public struct MemorySavedPayload: Codable, Sendable {
    public let episodeID: UUID
    public let stored: Bool
    public init(episodeID: UUID, stored: Bool) { self.episodeID = episodeID; self.stored = stored }
}
```

- [ ] **Run test — expect pass** `swift test --filter BantiEventTests 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/BantiEvent.swift Tests/BantiTests/BantiEventTests.swift
git commit -m "feat: add BantiEvent types — envelope + all payload structs"
```

---

## Task 3: EventBus

**Files:**
- Create: `Sources/BantiCore/EventBus.swift`
- Create: `Tests/BantiTests/EventBusTests.swift`

- [ ] **Write the failing tests**

```swift
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
```

- [ ] **Run test — expect failure** `swift test --filter EventBusTests 2>&1 | tail -5`

- [ ] **Implement**

```swift
// Sources/BantiCore/EventBus.swift
import Foundation

public typealias SubscriptionID = UUID

public actor EventBus {
    private var subscribers: [String: [(SubscriptionID, @Sendable (BantiEvent) async -> Void)]] = [:]

    public init() {}

    @discardableResult
    public func subscribe(
        topic: String,
        handler: @escaping @Sendable (BantiEvent) async -> Void
    ) -> SubscriptionID {
        let id = SubscriptionID()
        subscribers[topic, default: []].append((id, handler))
        return id
    }

    public func unsubscribe(_ id: SubscriptionID) {
        for key in subscribers.keys {
            subscribers[key]?.removeAll { $0.0 == id }
        }
    }

    public func publish(_ event: BantiEvent, topic: String) {
        for (pattern, handlers) in subscribers {
            guard topicMatches(topic, pattern: pattern) else { continue }
            for (_, handler) in handlers {
                let h = handler
                let e = event
                Task { await h(e) }
            }
        }
    }

    // MARK: - Internal (exposed for tests via @testable)

    func subscriberCount(for topic: String) -> Int {
        subscribers[topic]?.count ?? 0
    }

    // MARK: - Private

    private func topicMatches(_ topic: String, pattern: String) -> Bool {
        if pattern == "*" { return true }
        if pattern == topic { return true }
        if pattern.hasSuffix(".*") {
            let prefix = String(pattern.dropLast(2))
            return topic == prefix || topic.hasPrefix(prefix + ".")
        }
        return false
    }
}
```

- [ ] **Run test — expect pass** `swift test --filter EventBusTests 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/EventBus.swift Tests/BantiTests/EventBusTests.swift
git commit -m "feat: add EventBus actor — pub/sub with exact, wildcard, match-all topics"
```

---

## Task 4: CorticalNode Protocol

**Files:**
- Create: `Sources/BantiCore/CorticalNode.swift`

No dedicated test needed — protocol conformance is compiler-verified. The integration test comes from ContextAggregator in Task 5.

- [ ] **Implement**

```swift
// Sources/BantiCore/CorticalNode.swift
import Foundation

/// Every node in the cortical graph implements this protocol.
/// Sensor cortices are publishers only — their `subscribedTopics` is empty.
/// Gate, brain, memory, and motor nodes subscribe and publish.
public protocol CorticalNode: Actor {
    /// Unique identifier for this node, used in event `source` field.
    var id: String { get }

    /// Topics this node listens to. Empty for sensor cortices.
    var subscribedTopics: [String] { get }

    /// Register subscriptions and begin the node's internal loop.
    func start(bus: EventBus) async

    /// Process an incoming event. Implementations call `bus.publish()` for outputs.
    func handle(_ event: BantiEvent) async
}
```

- [ ] **Build to confirm no errors** `swift build 2>&1 | tail -3`

- [ ] **Commit**
```bash
git add Sources/BantiCore/CorticalNode.swift
git commit -m "feat: add CorticalNode protocol — universal node interface"
```

---

## Task 5: ContextAggregator

**Files:**
- Create: `Sources/BantiCore/ContextAggregator.swift`
- Create: `Tests/BantiTests/ContextAggregatorTests.swift`

- [ ] **Write the failing tests**

```swift
// Tests/BantiTests/ContextAggregatorTests.swift
import XCTest
@testable import BantiCore

final class ContextAggregatorTests: XCTestCase {

    func testSnapshotEmptyByDefault() async {
        let agg = ContextAggregator()
        let snap = await agg.snapshotJSON()
        XCTAssertEqual(snap, "{}")
    }

    func testAggregatesScreenEvent() async {
        let bus = EventBus()
        let agg = ContextAggregator()
        await agg.start(bus: bus)

        let screen = ScreenPayload(ocrLines: ["hello"], interpretation: "user is reading")
        await bus.publish(
            BantiEvent(source: "screen_cortex", topic: "sensor.screen", surprise: 0.5,
                       payload: .screenUpdate(screen)),
            topic: "sensor.screen"
        )
        try? await Task.sleep(nanoseconds: 50_000_000) // let Task dispatch complete

        let snap = await agg.snapshotJSON()
        XCTAssertTrue(snap.contains("user is reading"), "expected screen interpretation in snapshot, got: \(snap)")
    }

    func testAggregatesSpeechEvent() async {
        let bus = EventBus()
        let agg = ContextAggregator()
        await agg.start(bus: bus)

        let speech = SpeechPayload(transcript: "let's get to work", speakerID: "p1")
        await bus.publish(
            BantiEvent(source: "audio_cortex", topic: "sensor.audio", surprise: 0.9,
                       payload: .speechDetected(speech)),
            topic: "sensor.audio"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        let snap = await agg.snapshotJSON()
        XCTAssertTrue(snap.contains("let's get to work"), "expected transcript in snapshot")
    }

    func testSnapshotJSONIsValidJSON() async {
        let bus = EventBus()
        let agg = ContextAggregator()
        await agg.start(bus: bus)

        let face = FacePayload(
            boundingBox: CodableCGRect(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
            personID: "p1", personName: "Pavan", confidence: 0.9
        )
        await bus.publish(
            BantiEvent(source: "visual_cortex", topic: "sensor.visual", surprise: 0.6,
                       payload: .faceUpdate(face)),
            topic: "sensor.visual"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        let snap = await agg.snapshotJSON()
        let data = snap.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }
}
```

- [ ] **Run test — expect failure** `swift test --filter ContextAggregatorTests 2>&1 | tail -5`

- [ ] **Implement**

```swift
// Sources/BantiCore/ContextAggregator.swift
import Foundation

/// Subscribes to all sensor.* events and maintains last-known state for snapshotJSON().
/// Phase 1: parallel to PerceptionContext.
/// Phase 2: replaces PerceptionContext as the sole source of truth for the sidecar.
/// Phase 3: deleted when SelfModel migrates to episode.bound events.
public actor ContextAggregator: CorticalNode {
    public let id = "context_aggregator"
    public let subscribedTopics = ["sensor.*"]

    private var lastFace: FacePayload?
    private var lastScreen: ScreenPayload?
    private var lastEmotionFace: EmotionPayload?
    private var lastEmotionVoice: EmotionPayload?
    private var lastSpeech: SpeechPayload?
    private var lastSound: SoundPayload?

    public init() {}

    public func start(bus: EventBus) async {
        await bus.subscribe(topic: "sensor.*") { [weak self] event in
            await self?.handle(event)
        }
    }

    public func handle(_ event: BantiEvent) async {
        switch event.payload {
        case .faceUpdate(let p):    lastFace = p
        case .screenUpdate(let p):  lastScreen = p
        case .emotionUpdate(let p):
            if p.source == "hume_face" { lastEmotionFace = p }
            else { lastEmotionVoice = p }
        case .speechDetected(let p): lastSpeech = p
        case .soundUpdate(let p):   lastSound = p
        default: break
        }
    }

    /// Returns a compact JSON snapshot of last-known state.
    /// Mirrors the format previously produced by PerceptionContext.snapshotJSON().
    public func snapshotJSON() -> String {
        var dict: [String: Any] = [:]
        if let f = lastFace {
            dict["face"] = ["personID": f.personID as Any,
                            "personName": f.personName as Any,
                            "confidence": f.confidence]
        }
        if let s = lastScreen {
            dict["screen"] = ["ocrLines": s.ocrLines, "interpretation": s.interpretation]
        }
        if let e = lastEmotionFace {
            dict["emotion"] = e.emotions.map { ["label": $0.label, "score": $0.score] }
        }
        if let e = lastEmotionVoice {
            dict["voiceEmotion"] = e.emotions.map { ["label": $0.label, "score": $0.score] }
        }
        if let sp = lastSpeech {
            dict["speech"] = ["transcript": sp.transcript, "speakerID": sp.speakerID as Any]
        }
        if let so = lastSound {
            dict["sound"] = ["label": so.label, "confidence": so.confidence]
        }
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
```

- [ ] **Run test — expect pass** `swift test --filter ContextAggregatorTests 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/ContextAggregator.swift Tests/BantiTests/ContextAggregatorTests.swift
git commit -m "feat: add ContextAggregator — aggregates sensor.* events for sidecar snapshot"
```

---

## Task 6: Adapt PerceptionRouter

`PerceptionRouter` gains an optional `EventBus`. At the end of `dispatch()`, after updating `PerceptionContext` (unchanged), it also publishes typed events to the bus. All existing tests must still pass.

**Files:**
- Modify: `Sources/BantiCore/PerceptionRouter.swift`

- [ ] **Add bus property and `setBus` method** (no test needed — regression tests cover this)

In `PerceptionRouter`:
```swift
// Add at top of actor:
private var bus: EventBus?

// Add new public method:
public func setBus(_ bus: EventBus) {
    self.bus = bus
}
```

- [ ] **Publish face event after face detection** — in the `if case .faceDetected(let obs)` block, after `await context.update(.face(state))`:

```swift
if let bus, let person = await context.person {
    let payload = FacePayload(
        boundingBox: state.boundingBox,
        personID: person.id,
        personName: person.name,
        confidence: person.confidence
    )
    let event = BantiEvent(source: "visual_cortex", topic: "sensor.visual",
                           surprise: 0.5, payload: .faceUpdate(payload))
    await bus.publish(event, topic: "sensor.visual")
}
```

- [ ] **Publish screen event** — in the screen analyzer Task closure, after `await self.context.update(...)`, add:

```swift
if let bus = await self.bus, let state = /* the ScreenState just stored */ {
    let payload = ScreenPayload(ocrLines: state.ocrLines, interpretation: state.interpretation)
    let event = BantiEvent(source: "visual_cortex", topic: "sensor.screen",
                           surprise: 0.6, payload: .screenUpdate(payload))
    await bus.publish(event, topic: "sensor.screen")
}
```

Note: the screen update already happens inside a `Task` in `dispatch()`. The bus publish goes inside that same `Task`, after the context update.

- [ ] **Run all existing tests — expect pass** `swift test 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/PerceptionRouter.swift
git commit -m "feat: PerceptionRouter publishes face/screen events to EventBus (parallel path)"
```

---

## Task 7: Adapt AudioRouter

**Files:**
- Modify: `Sources/BantiCore/AudioRouter.swift`

AudioRouter needs an optional `EventBus`. It publishes `sensor.audio` on transcript (in `setTranscriptCallback`) and on Hume voice emotion (in `dispatch()`).

- [ ] **Add bus property**

```swift
private var bus: EventBus?

public func setBus(_ bus: EventBus) {
    self.bus = bus
}
```

- [ ] **Publish speech event from transcript callback**

In `setTranscriptCallback`, wrap the user-supplied callback so it also publishes:

```swift
public func setTranscriptCallback(_ callback: @escaping @Sendable (String) async -> Void) async {
    let capturedBus = bus
    await deepgram?.setTranscriptCallback { @Sendable transcript in
        await callback(transcript)
        if let b = capturedBus {
            let event = BantiEvent(source: "audio_cortex", topic: "sensor.audio",
                                   surprise: 1.0,
                                   payload: .speechDetected(SpeechPayload(transcript: transcript, speakerID: nil)))
            await b.publish(event, topic: "sensor.audio")
        }
    }
}
```

**Important:** `capturedBus` is captured at call time (when `setTranscriptCallback` is called). If the bus is set after this, the transcript callback won't see it. Call `setBus` before `setTranscriptCallback` in `MemoryEngine.start()`.

- [ ] **Publish emotion event from Hume**

In `dispatch()`, after the Hume `Task` calls `self.context.update(.voiceEmotion(state))`, add a bus publish inside the same Task:

```swift
if let bus = await self.bus, let state {
    let emotions = state.emotions.map {
        EmotionPayload.Emotion(label: $0.label, score: $0.score)
    }
    let payload = EmotionPayload(emotions: emotions, source: "hume_voice")
    let event = BantiEvent(source: "audio_cortex", topic: "sensor.audio",
                           surprise: 0.4, payload: .emotionUpdate(payload))
    await bus.publish(event, topic: "sensor.audio")
}
```

- [ ] **Run all tests — expect pass** `swift test 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/AudioRouter.swift
git commit -m "feat: AudioRouter publishes sensor.audio events to EventBus (parallel path)"
```

---

## Task 8: Adapt BantiVoice (efference copy groundwork)

`BantiVoice` publishes `motor.voice` events when speaking starts and ends. These are consumed by `AudioCortex` in Phase 2.

**Files:**
- Modify: `Sources/BantiCore/BantiVoice.swift`

- [ ] **Add bus property**

```swift
private var bus: EventBus?

public func setBus(_ bus: EventBus) {
    self.bus = bus
}
```

- [ ] **Publish `motor.voice` on `say()`**

At the start of `say(_:track:)`, before `cartesiaSpeaker.streamSpeak`, estimate duration (300ms per word as a rough heuristic) and publish:

```swift
let wordCount = text.split(separator: " ").count
let estimatedMs = max(500, wordCount * 300)
if let b = bus {
    let event = BantiEvent(source: "banti_voice", topic: "motor.voice", surprise: 0.0,
                           payload: .voiceSpeaking(VoiceSpeakingPayload(
                               speaking: true,
                               estimatedDurationMs: estimatedMs,
                               tailWindowMs: 5000,
                               text: text)))
    await b.publish(event, topic: "motor.voice")
}
```

- [ ] **Publish `motor.voice` stop on `markPlaybackEnded()`**

```swift
if let b = bus {
    let event = BantiEvent(source: "banti_voice", topic: "motor.voice", surprise: 0.0,
                           payload: .voiceSpeaking(VoiceSpeakingPayload(
                               speaking: false,
                               estimatedDurationMs: 0,
                               tailWindowMs: 5000,
                               text: nil)))
    await b.publish(event, topic: "motor.voice")
}
```

- [ ] **Run all tests — expect pass** `swift test 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/BantiVoice.swift
git commit -m "feat: BantiVoice publishes motor.voice efference copy events to EventBus"
```

---

## Task 9: Wire EventBus into MemoryEngine

**Files:**
- Modify: `Sources/BantiCore/MemoryEngine.swift`

- [ ] **Create EventBus in MemoryEngine.init, store as public let**

```swift
public let eventBus: EventBus

// In init, before other properties:
self.eventBus = EventBus()
```

- [ ] **Pass bus to PerceptionRouter, AudioRouter, BantiVoice in `start()`**

In `MemoryEngine.start()`, after `await sidecar.start()` and before `await brainLoop.start()`:

```swift
// Wire EventBus to components that publish
await router.setBus(eventBus)      // router is PerceptionRouter passed in externally
await audioRouter.setBus(eventBus)
await bantiVoice.setBus(eventBus)

// Start ContextAggregator
let aggregator = ContextAggregator()
await aggregator.start(bus: eventBus)
```

Note: `MemoryEngine` doesn't currently hold a reference to `PerceptionRouter`. The simplest Phase 1 approach is to store the bus on `MemoryEngine` as a public property and let `main.swift` wire it to the router after both are created.

- [ ] **Update main.swift** to wire the bus to the router:

```swift
// After `Task { await memoryEngine.start() }`:
Task {
    await router.setBus(memoryEngine.eventBus)
}
```

- [ ] **Run all tests — expect pass** `swift test 2>&1 | tail -5`

- [ ] **Run the app smoke test** `swift run banti 2>&1 | head -20` — should log `banti running` with no new errors

- [ ] **Commit**
```bash
git add Sources/BantiCore/MemoryEngine.swift Sources/banti/main.swift
git commit -m "feat: wire EventBus through MemoryEngine — Phase 1 infrastructure complete"
```

---

## Task 10: Phase 1 Regression Check

- [ ] **Run full test suite** `swift test 2>&1 | tail -10`
  Expected: all 190+ tests pass (the new tests add to the count; none break)

- [ ] **Verify bus events are flowing** — temporarily add a `BrainMonitor`-style subscriber in `main.swift` that logs every event:

```swift
Task {
    await memoryEngine.eventBus.subscribe(topic: "*") { event in
        print("[bus] \(event.source) → \(event.topic)")
    }
}
```

Run `swift run banti`, speak a sentence, verify `[bus] audio_cortex → sensor.audio` appears in logs. Remove the debug subscriber before committing.

- [ ] **Final commit**
```bash
git commit -m "chore: Phase 1 complete — EventBus wired, all 190+ tests pass"
```
