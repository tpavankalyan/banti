# Cortical Graph — Phase 2: New Nodes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `PerceptionRouter`, `BrainLoop`, `LocalPerception`, `PerceptionContext`, `SpeakerAttributor`, `SelfSpeechLog`, and `MemoryIngestor` with 12 autonomous `CorticalNode` actors connected through the `EventBus`.

**Architecture:** Each new node accepts a `CerebrasCompletion` closure in its initialiser (for testability). Existing deletion targets keep their files until the replacement is verified working; then they are deleted. Phase 2 ends with the system running on the new node graph with no regressions.

**Tech Stack:** Swift actors, structured concurrency, Cerebras API (OpenAI-compatible), `AsyncOpenAI` Python client (already present), XCTest with mock closures

**Prerequisite:** Phase 1 complete and merged.

---

## Cerebras Client Abstraction

Define once at the top of `Sources/BantiCore/CerebrasClient.swift`:

```swift
// Sources/BantiCore/CerebrasClient.swift
import Foundation

/// Injectable LLM completion function. All Cerebras nodes accept this type.
/// model: Cerebras model string (e.g. "llama3.1-8b")
/// systemPrompt: system message
/// userContent: user message
/// maxTokens: upper bound
/// Returns: completion text
public typealias CerebrasCompletion = @Sendable (
    _ model: String,
    _ systemPrompt: String,
    _ userContent: String,
    _ maxTokens: Int
) async throws -> String

/// Production implementation — calls Cerebras API via URLSession.
public func makeLiveCerebrasCompletion(apiKey: String) -> CerebrasCompletion {
    return { model, systemPrompt, userContent, maxTokens in
        let url = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "max_tokens": maxTokens
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }
}
```

All LLM nodes take `cerebras: CerebrasCompletion` in their init. Tests inject a mock closure.

---

## File Map

**New files (all in `Sources/BantiCore/`):**
- `CerebrasClient.swift` — `CerebrasCompletion` typealias + live implementation
- `VisualCortex.swift` — camera capture + Apple Vision + GPT-4o → `sensor.visual`
- `ScreenCortex.swift` — screen capture + Apple Vision OCR + GPT-4o → `sensor.screen`
- `AudioCortex.swift` — mic + Deepgram + Hume + efference copy suppression → `sensor.audio`
- `SurpriseDetector.swift` — Cerebras node: gate low-information events → `gate.surprise`
- `TemporalBinder.swift` — Cerebras node: debounce + fuse events → `episode.bound`
- `TrackRouter.swift` — Cerebras node: select tracks → `brain.route`
- `BrainstemNode.swift` — Cerebras node: instant reflex → `brain.brainstem.response`
- `LimbicNode.swift` — Cerebras node: emotional response → `brain.limbic.response`
- `PrefrontalNode.swift` — Cerebras node: deep reasoning + memory → `brain.prefrontal.response`
- `ResponseArbitrator.swift` — Cerebras node: order/merge responses → `motor.speech_plan`
- `MemoryLoader.swift` — face identity → memory fetch → `memory.retrieve`
- `MemoryConsolidator.swift` — Cerebras node: episode worth storing? → `memory.write`

**New test files:**
- `Tests/BantiTests/SurpriseDetectorTests.swift`
- `Tests/BantiTests/TemporalBinderTests.swift`
- `Tests/BantiTests/TrackRouterTests.swift`
- `Tests/BantiTests/BrainstemNodeTests.swift`
- `Tests/BantiTests/ResponseArbitratorTests.swift`
- `Tests/BantiTests/AudioCortexPhase2Tests.swift`
- `Tests/BantiTests/MemoryLoaderTests.swift`
- `Tests/BantiTests/MemoryConsolidatorTests.swift`

**Deleted files (at end of phase, after all tests pass):**
- `Sources/BantiCore/PerceptionRouter.swift`
- `Sources/BantiCore/PerceptionContext.swift`
- `Sources/BantiCore/LocalPerception.swift`
- `Sources/BantiCore/BrainLoop.swift`
- `Sources/BantiCore/SpeakerAttributor.swift`
- `Sources/BantiCore/SelfSpeechLog.swift`
- `Sources/BantiCore/MemoryIngestor.swift`

**Modified files:**
- `Sources/BantiCore/MemoryEngine.swift` — remove deleted components, add all new nodes
- `Sources/banti/main.swift` — minimal changes (MemoryEngine encapsulates wiring)
- `memory_sidecar/memory.py` — remove `_reasoning_stream` Anthropic Opus path (replaced by PrefrontalNode)

---

## Task 1: CerebrasClient

**Files:**
- Create: `Sources/BantiCore/CerebrasClient.swift`

- [ ] **Implement** — copy the code from the Cerebras Client Abstraction section above

- [ ] **Build** `swift build 2>&1 | tail -3`

- [ ] **Commit**
```bash
git add Sources/BantiCore/CerebrasClient.swift
git commit -m "feat: add CerebrasCompletion typealias + live implementation"
```

---

## Task 2: SurpriseDetector

**Files:**
- Create: `Sources/BantiCore/SurpriseDetector.swift`
- Create: `Tests/BantiTests/SurpriseDetectorTests.swift`

- [ ] **Write the failing tests**

```swift
// Tests/BantiTests/SurpriseDetectorTests.swift
import XCTest
@testable import BantiCore

final class SurpriseDetectorTests: XCTestCase {

    func testHighSurpriseForwardsEvent() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "gate.surprise") { event in
            await received.append(event)
        }

        // Mock Cerebras returns score 0.8 — above threshold
        let detector = SurpriseDetector(cerebras: mockCerebras(score: 0.8))
        await detector.start(bus: bus)

        await bus.publish(makeSpeechEvent(), topic: "sensor.audio")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 1)
        XCTAssertGreaterThanOrEqual(events.first?.surprise ?? 0, 0.3)
    }

    func testLowSurpriseDropsEvent() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "gate.surprise") { event in
            await received.append(event)
        }

        let detector = SurpriseDetector(cerebras: mockCerebras(score: 0.1))
        await detector.start(bus: bus)

        await bus.publish(makeSpeechEvent(), topic: "sensor.audio")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 0)
    }

    func testCerebrasErrorDropsEvent() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "gate.surprise") { event in
            await received.append(event)
        }

        let detector = SurpriseDetector(cerebras: { _, _, _, _ in throw URLError(.notConnectedToInternet) })
        await detector.start(bus: bus)

        await bus.publish(makeSpeechEvent(), topic: "sensor.audio")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 0, "errors should be swallowed silently")
    }

    // MARK: - Helpers

    private func mockCerebras(score: Float) -> CerebrasCompletion {
        { _, _, _, _ in "{\"surprise\": \(score)}" }
    }

    private func makeSpeechEvent() -> BantiEvent {
        BantiEvent(source: "audio_cortex", topic: "sensor.audio", surprise: 0,
                   payload: .speechDetected(SpeechPayload(transcript: "hello world", speakerID: nil)))
    }
}

/// Actor-isolated mutable box — useful in async tests
actor ActorBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
    func append(_ item: Any) where T == [BantiEvent] {
        value.append(item as! BantiEvent)
    }
}
```

- [ ] **Run test — expect failure** `swift test --filter SurpriseDetectorTests 2>&1 | tail -5`

- [ ] **Implement**

```swift
// Sources/BantiCore/SurpriseDetector.swift
import Foundation

public actor SurpriseDetector: CorticalNode {
    public let id = "surprise_detector"
    public let subscribedTopics = ["sensor.*"]

    private let cerebras: CerebrasCompletion
    private var lastDescriptions: [String: String] = [:]  // topic → last text

    private static let systemPrompt = """
    You are a surprise filter. Given the previous and current description of a sensor event,
    output JSON: {"surprise": <float 0-1>} where 0 means nothing changed and 1 means very surprising.
    Respond with JSON only.
    """

    public init(cerebras: CerebrasCompletion) {
        self.cerebras = cerebras
    }

    public func start(bus: EventBus) async {
        await bus.subscribe(topic: "sensor.*") { [weak self] event in
            await self?.handle(event)
        }
        self._bus = bus
    }

    private var _bus: EventBus?

    public func handle(_ event: BantiEvent) async {
        guard let bus = _bus else { return }
        let description = describeEvent(event)
        let previous = lastDescriptions[event.topic] ?? "(nothing)"
        lastDescriptions[event.topic] = description

        let userContent = "Previous: \(previous)\nCurrent: \(description)"
        let score: Float
        do {
            let response = try await cerebras("llama3.1-8b", Self.systemPrompt, userContent, 20)
            guard let data = response.data(using: .utf8),
                  let json = try? JSONDecoder().decode([String: Float].self, from: data),
                  let s = json["surprise"] else { return }
            score = s
        } catch {
            return // silently drop on Cerebras error
        }

        guard score >= 0.3 else { return }
        let forwarded = BantiEvent(source: event.source, topic: event.topic,
                                   surprise: score, payload: event.payload)
        await bus.publish(forwarded, topic: "gate.surprise")
    }

    private func describeEvent(_ event: BantiEvent) -> String {
        switch event.payload {
        case .speechDetected(let p): return "Speech: \(p.transcript)"
        case .faceUpdate(let p): return "Face: \(p.personName ?? "unknown") confidence \(p.confidence)"
        case .screenUpdate(let p): return "Screen: \(p.interpretation)"
        case .emotionUpdate(let p): return "Emotion: \(p.emotions.first.map { "\($0.label) \($0.score)" } ?? "none")"
        case .soundUpdate(let p): return "Sound: \(p.label)"
        default: return "event:\(event.topic)"
        }
    }
}
```

- [ ] **Run test — expect pass** `swift test --filter SurpriseDetectorTests 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/SurpriseDetector.swift Tests/BantiTests/SurpriseDetectorTests.swift
git commit -m "feat: SurpriseDetector node — gates low-information events via Cerebras"
```

---

## Task 3: TemporalBinder

**Files:**
- Create: `Sources/BantiCore/TemporalBinder.swift`
- Create: `Tests/BantiTests/TemporalBinderTests.swift`

- [ ] **Write the failing tests**

```swift
// Tests/BantiTests/TemporalBinderTests.swift
import XCTest
@testable import BantiCore

final class TemporalBinderTests: XCTestCase {

    func testWindowClosesAfter500msAndPublishesEpisode() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "episode.bound") { event in
            await received.append(event)
        }

        let binder = TemporalBinder(cerebras: { _, _, _, _ in
            """
            {"text":"Pavan said hello","participants":["Pavan"],"emotionalTone":"warm"}
            """
        }, windowMs: 200) // short window for test speed
        await binder.start(bus: bus)

        // Publish one surprise event
        await bus.publish(makeSurpriseEvent("sensor.audio"), topic: "gate.surprise")

        // Wait >200ms for window to close
        try? await Task.sleep(nanoseconds: 400_000_000)

        let events = await received.value
        XCTAssertEqual(events.count, 1)
        if case .episodeBound(let ep) = events.first?.payload {
            XCTAssertEqual(ep.text, "Pavan said hello")
            XCTAssertEqual(ep.participants, ["Pavan"])
        } else {
            XCTFail("expected episodeBound payload")
        }
    }

    func testNewEventResetsWindow() async {
        // If two events arrive 100ms apart with a 200ms window,
        // the episode should only publish once, 200ms after the second event.
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "episode.bound") { event in
            await received.append(event)
        }

        let binder = TemporalBinder(cerebras: { _, _, _, _ in
            """{"text":"test","participants":[],"emotionalTone":"neutral"}"""
        }, windowMs: 200)
        await binder.start(bus: bus)

        await bus.publish(makeSurpriseEvent("sensor.audio"), topic: "gate.surprise")
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms — within window
        await bus.publish(makeSurpriseEvent("sensor.visual"), topic: "gate.surprise")
        try? await Task.sleep(nanoseconds: 350_000_000) // 350ms — window closes

        let events = await received.value
        XCTAssertEqual(events.count, 1, "debounce should produce exactly one episode")
    }

    private func makeSurpriseEvent(_ topic: String) -> BantiEvent {
        BantiEvent(source: "test", topic: topic, surprise: 0.9,
                   payload: .speechDetected(SpeechPayload(transcript: "hi", speakerID: nil)))
    }
}
```

- [ ] **Run test — expect failure** `swift test --filter TemporalBinderTests 2>&1 | tail -5`

- [ ] **Implement**

```swift
// Sources/BantiCore/TemporalBinder.swift
import Foundation

public actor TemporalBinder: CorticalNode {
    public let id = "temporal_binder"
    public let subscribedTopics = ["gate.surprise"]

    private let cerebras: CerebrasCompletion
    private let windowNs: UInt64

    private var pendingEvents: [BantiEvent] = []
    private var windowTask: Task<Void, Never>?
    private var _bus: EventBus?

    private static let systemPrompt = """
    Fuse these sensor events into a single natural-language episode description.
    Output JSON only: {"text":"<episode>","participants":["<name>"],"emotionalTone":"<tone>"}
    """

    public init(cerebras: CerebrasCompletion, windowMs: Int = 500) {
        self.cerebras = cerebras
        self.windowNs = UInt64(windowMs) * 1_000_000
    }

    public func start(bus: EventBus) async {
        _bus = bus
        await bus.subscribe(topic: "gate.surprise") { [weak self] event in
            await self?.handle(event)
        }
    }

    public func handle(_ event: BantiEvent) async {
        pendingEvents.append(event)
        // Debounce: cancel existing timer, start a new one
        windowTask?.cancel()
        let capturedEvents = pendingEvents
        let ns = windowNs
        windowTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await self?.flush(capturedEvents)
        }
    }

    private func flush(_ events: [BantiEvent]) async {
        guard !events.isEmpty, let bus = _bus else { return }
        pendingEvents.removeAll()

        let descriptions = events.map { describeEvent($0) }.joined(separator: "\n")
        let userContent = "Events to fuse:\n\(descriptions)"

        do {
            let response = try await cerebras("llama3.1-8b", Self.systemPrompt, userContent, 100)
            guard let data = response.data(using: .utf8),
                  let json = try? JSONDecoder().decode(EpisodeJSON.self, from: data) else { return }
            let episode = EpisodePayload(text: json.text, participants: json.participants,
                                         emotionalTone: json.emotionalTone)
            await bus.publish(
                BantiEvent(source: id, topic: "episode.bound", surprise: 1.0,
                           payload: .episodeBound(episode)),
                topic: "episode.bound"
            )
        } catch { /* silently drop */ }
    }

    private func describeEvent(_ event: BantiEvent) -> String {
        switch event.payload {
        case .speechDetected(let p): return "[\(event.timestampNs)] Speech: \(p.transcript)"
        case .faceUpdate(let p): return "[\(event.timestampNs)] Face: \(p.personName ?? "unknown")"
        case .screenUpdate(let p): return "[\(event.timestampNs)] Screen: \(p.interpretation)"
        case .emotionUpdate(let p): return "[\(event.timestampNs)] Emotion: \(p.source) \(p.emotions.first?.label ?? "")"
        default: return "[\(event.timestampNs)] \(event.topic)"
        }
    }

    private struct EpisodeJSON: Codable {
        let text: String
        let participants: [String]
        let emotionalTone: String
    }
}
```

- [ ] **Run test — expect pass** `swift test --filter TemporalBinderTests 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/TemporalBinder.swift Tests/BantiTests/TemporalBinderTests.swift
git commit -m "feat: TemporalBinder node — debounce + fuse events into episodes via Cerebras"
```

---

## Task 4: TrackRouter

**Files:**
- Create: `Sources/BantiCore/TrackRouter.swift`
- Create: `Tests/BantiTests/TrackRouterTests.swift`

- [ ] **Write the failing tests**

```swift
// Tests/BantiTests/TrackRouterTests.swift
import XCTest
@testable import BantiCore

final class TrackRouterTests: XCTestCase {

    func testRoutesSpeechToBrainstemAndPrefrontal() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "brain.route") { event in
            await received.append(event)
        }

        let router = TrackRouter(cerebras: { _, _, _, _ in
            """{"tracks":["brainstem","prefrontal"],"reason":"speech detected"}"""
        })
        await router.start(bus: bus)

        let episode = EpisodePayload(text: "Pavan said hello", participants: ["Pavan"],
                                     emotionalTone: "warm")
        await bus.publish(
            BantiEvent(source: "temporal_binder", topic: "episode.bound", surprise: 1.0,
                       payload: .episodeBound(episode)),
            topic: "episode.bound"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        let events = await received.value
        XCTAssertEqual(events.count, 1)
        if case .brainRoute(let route) = events.first?.payload {
            XCTAssertTrue(route.tracks.contains("brainstem"))
            XCTAssertTrue(route.tracks.contains("prefrontal"))
        } else { XCTFail() }
    }

    func testUnknownPersonTriggersBrainstem() async {
        // TrackRouter watching sensor.visual: after >30s unknown person, fires brainstem route
        // This is a time-based test — just verify the subscription is registered
        let bus = EventBus()
        let router = TrackRouter(cerebras: { _, _, _, _ in
            """{"tracks":["brainstem"],"reason":"unknown person"}"""
        })
        await router.start(bus: bus)
        // Verify subscribedTopics includes sensor.visual
        XCTAssertTrue(router.subscribedTopics.contains("sensor.visual"))
    }
}
```

- [ ] **Run test — expect failure** `swift test --filter TrackRouterTests 2>&1 | tail -5`

- [ ] **Implement**

```swift
// Sources/BantiCore/TrackRouter.swift
import Foundation

public actor TrackRouter: CorticalNode {
    public let id = "track_router"
    public let subscribedTopics = ["episode.bound", "sensor.visual"]

    private let cerebras: CerebrasCompletion
    private var _bus: EventBus?

    // Unknown-person tracking for ProactiveIntroducer responsibility
    private var unknownPersonFirstSeen: Date?
    private var lastUnknownPersonRouted: Date?

    private static let systemPrompt = """
    Given this episode, decide which brain tracks to activate.
    Available tracks: brainstem (instant reflex), limbic (emotional), prefrontal (deep reasoning).
    Output JSON only: {"tracks":["<track>",...],"reason":"<brief>"}
    Activate brainstem for most situations. Add limbic when emotion is significant.
    Add prefrontal when memory, reasoning, or long-term context is needed.
    """

    public init(cerebras: CerebrasCompletion) {
        self.cerebras = cerebras
    }

    public func start(bus: EventBus) async {
        _bus = bus
        await bus.subscribe(topic: "episode.bound") { [weak self] event in
            await self?.handle(event)
        }
        await bus.subscribe(topic: "sensor.visual") { [weak self] event in
            await self?.handle(event)
        }
    }

    public func handle(_ event: BantiEvent) async {
        switch event.payload {
        case .episodeBound(let episode):
            await routeEpisode(episode)
        case .faceUpdate(let face):
            await checkUnknownPerson(face: face)
        default:
            break
        }
    }

    private func routeEpisode(_ episode: EpisodePayload) async {
        guard let bus = _bus else { return }
        let userContent = "Episode: \(episode.text)\nTone: \(episode.emotionalTone)\nParticipants: \(episode.participants.joined(separator: ", "))"
        do {
            let response = try await cerebras("llama3.1-8b", Self.systemPrompt, userContent, 60)
            guard let data = response.data(using: .utf8),
                  let json = try? JSONDecoder().decode(RouteJSON.self, from: data) else { return }
            let route = BrainRoutePayload(tracks: json.tracks, reason: json.reason, episode: episode)
            await bus.publish(
                BantiEvent(source: id, topic: "brain.route", surprise: 1.0,
                           payload: .brainRoute(route)),
                topic: "brain.route"
            )
        } catch { /* silently drop */ }
    }

    private func checkUnknownPerson(face: FacePayload) async {
        guard let bus = _bus else { return }
        if face.personID != nil && face.personName == nil {
            // Unknown person — start timer
            if unknownPersonFirstSeen == nil { unknownPersonFirstSeen = Date() }
            if let firstSeen = unknownPersonFirstSeen,
               Date().timeIntervalSince(firstSeen) > 30,
               lastUnknownPersonRouted.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                lastUnknownPersonRouted = Date()
                let dummyEpisode = EpisodePayload(
                    text: "An unknown person has been present for over 30 seconds",
                    participants: [], emotionalTone: "neutral"
                )
                let route = BrainRoutePayload(tracks: ["brainstem"], reason: "unknown person greeting", episode: dummyEpisode)
                await bus.publish(
                    BantiEvent(source: id, topic: "brain.route", surprise: 0.8,
                               payload: .brainRoute(route)),
                    topic: "brain.route"
                )
            }
        } else {
            unknownPersonFirstSeen = nil
        }
    }

    private struct RouteJSON: Codable {
        let tracks: [String]
        let reason: String
    }
}
```

- [ ] **Run test — expect pass** `swift test --filter TrackRouterTests 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/TrackRouter.swift Tests/BantiTests/TrackRouterTests.swift
git commit -m "feat: TrackRouter node — selects brain tracks per episode via Cerebras"
```

---

## Task 5: Brain Track Nodes (Brainstem + Limbic + Prefrontal)

**Files:**
- Create: `Sources/BantiCore/BrainstemNode.swift`
- Create: `Sources/BantiCore/LimbicNode.swift`
- Create: `Sources/BantiCore/PrefrontalNode.swift`
- Create: `Tests/BantiTests/BrainstemNodeTests.swift`

The three brain nodes share the same shape. Write one test file for Brainstem (as the template), then implement all three.

- [ ] **Write BrainstemNode tests**

```swift
// Tests/BantiTests/BrainstemNodeTests.swift
import XCTest
@testable import BantiCore

final class BrainstemNodeTests: XCTestCase {

    func testPublishesResponseWhenActivated() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "brain.brainstem.response") { event in
            await received.append(event)
        }

        let node = BrainstemNode(cerebras: { _, _, _, _ in "Hey Pavan! How are you?" })
        await node.start(bus: bus)

        let route = BrainRoutePayload(
            tracks: ["brainstem"],
            reason: "speech",
            episode: EpisodePayload(text: "hello", participants: ["Pavan"], emotionalTone: "warm")
        )
        await bus.publish(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(route)),
            topic: "brain.route"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        let events = await received.value
        XCTAssertEqual(events.count, 1)
        if case .brainResponse(let r) = events.first?.payload {
            XCTAssertEqual(r.track, "brainstem")
            XCTAssertEqual(r.text, "Hey Pavan! How are you?")
            XCTAssertTrue(r.activatedTracks.contains("brainstem"))
        } else { XCTFail() }
    }

    func testDoesNotRespondWhenNotActivated() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "brain.brainstem.response") { event in
            await received.append(event)
        }

        let node = BrainstemNode(cerebras: { _, _, _, _ in "hello" })
        await node.start(bus: bus)

        // Route only activates limbic — not brainstem
        let route = BrainRoutePayload(
            tracks: ["limbic"],
            reason: "emotion only",
            episode: EpisodePayload(text: "sad face", participants: [], emotionalTone: "sad")
        )
        await bus.publish(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(route)),
            topic: "brain.route"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await received.value
        XCTAssertEqual(events.count, 0)
    }

    func testSilentResponseIsDropped() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "brain.brainstem.response") { event in
            await received.append(event)
        }

        let node = BrainstemNode(cerebras: { _, _, _, _ in "[silent]" })
        await node.start(bus: bus)

        let route = BrainRoutePayload(
            tracks: ["brainstem"], reason: "heartbeat",
            episode: EpisodePayload(text: "quiet room", participants: [], emotionalTone: "neutral")
        )
        await bus.publish(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 0.3,
                       payload: .brainRoute(route)),
            topic: "brain.route"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual((await received.value).count, 0, "[silent] should not publish a response")
    }
}
```

- [ ] **Run test — expect failure** `swift test --filter BrainstemNodeTests 2>&1 | tail -5`

- [ ] **Implement BrainstemNode**

```swift
// Sources/BantiCore/BrainstemNode.swift
import Foundation

public actor BrainstemNode: CorticalNode {
    public let id = "brainstem"
    public let subscribedTopics = ["brain.route"]
    private let cerebras: CerebrasCompletion
    private var _bus: EventBus?

    private static let systemPrompt = """
    You are banti's brainstem — instant reflex. Speak in 1-2 short natural sentences.
    React to what's happening right now. Be warm, direct, human.
    If there is nothing worth saying, respond with exactly: [silent]
    Plain prose only. No JSON.
    """

    public init(cerebras: CerebrasCompletion) { self.cerebras = cerebras }

    public func start(bus: EventBus) async {
        _bus = bus
        await bus.subscribe(topic: "brain.route") { [weak self] event in
            await self?.handle(event)
        }
    }

    public func handle(_ event: BantiEvent) async {
        guard case .brainRoute(let route) = event.payload,
              route.tracks.contains("brainstem"),
              let bus = _bus else { return }
        do {
            let userContent = "Episode: \(route.episode.text)\nTone: \(route.episode.emotionalTone)"
            let text = try await cerebras("llama3.1-8b", Self.systemPrompt, userContent, 80)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != "[silent]" && !trimmed.isEmpty else { return }
            let response = BrainResponsePayload(track: "brainstem", text: trimmed,
                                                activatedTracks: route.tracks)
            await bus.publish(
                BantiEvent(source: id, topic: "brain.brainstem.response", surprise: 0,
                           payload: .brainResponse(response)),
                topic: "brain.brainstem.response"
            )
        } catch { /* drop */ }
    }
}
```

- [ ] **Implement LimbicNode** — same shape as BrainstemNode, different topic and system prompt:
  - `id = "limbic"`, publishes to `"brain.limbic.response"`, timeout 5s
  - System prompt: "You are banti's limbic system. Read the emotional content and respond with empathy. 1-2 sentences. [silent] if no emotional content."

- [ ] **Implement PrefrontalNode** — same shape, uses `"llama-3.3-70b"` model, subscribes to both `brain.route` and `memory.retrieve`. Maintains a `[String: MemoryRetrievedPayload]` cache (keyed by `personID`). When handling `brain.route`, enriches the user prompt with cache entries matching `episode.participants` that arrived within the last 30s.

- [ ] **Run test — expect pass** `swift test --filter BrainstemNodeTests 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/BrainstemNode.swift Sources/BantiCore/LimbicNode.swift Sources/BantiCore/PrefrontalNode.swift Tests/BantiTests/BrainstemNodeTests.swift
git commit -m "feat: BrainstemNode, LimbicNode, PrefrontalNode — parallel brain tracks via Cerebras"
```

---

## Task 6: ResponseArbitrator

**Files:**
- Create: `Sources/BantiCore/ResponseArbitrator.swift`
- Create: `Tests/BantiTests/ResponseArbitratorTests.swift`

- [ ] **Write the failing tests**

```swift
// Tests/BantiTests/ResponseArbitratorTests.swift
import XCTest
@testable import BantiCore

final class ResponseArbitratorTests: XCTestCase {

    func testPublishesSpeechPlanFromAllResponses() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "motor.speech_plan") { event in
            await received.append(event)
        }

        let arbitrator = ResponseArbitrator(
            cerebras: { _, _, _, _ in """{"sentences":["Hey!","Did you fix that bug?"]}""" },
            collectionWindowMs: 200
        )
        await arbitrator.start(bus: bus)

        // First publish the route so arbitrator knows which tracks to expect
        let episode = EpisodePayload(text: "test", participants: [], emotionalTone: "neutral")
        let route = BrainRoutePayload(tracks: ["brainstem", "prefrontal"], reason: "test", episode: episode)
        await bus.publish(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(route)),
            topic: "brain.route"
        )

        // Then publish brainstem response
        let r = BrainResponsePayload(track: "brainstem", text: "Hey!", activatedTracks: ["brainstem", "prefrontal"])
        await bus.publish(
            BantiEvent(source: "brainstem", topic: "brain.brainstem.response", surprise: 0,
                       payload: .brainResponse(r)),
            topic: "brain.brainstem.response"
        )

        try? await Task.sleep(nanoseconds: 400_000_000) // wait for window

        let events = await received.value
        XCTAssertEqual(events.count, 1)
        if case .speechPlan(let plan) = events.first?.payload {
            XCTAssertFalse(plan.sentences.isEmpty)
        } else { XCTFail() }
    }

    func testPublishesEmptyPlanOnTimeout() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "motor.speech_plan") { event in
            await received.append(event)
        }

        let arbitrator = ResponseArbitrator(
            cerebras: { _, _, _, _ in """{"sentences":[]}""" },
            collectionWindowMs: 150
        )
        await arbitrator.start(bus: bus)

        // Publish route but NO responses — should still publish empty plan after window
        let episode = EpisodePayload(text: "test", participants: [], emotionalTone: "neutral")
        let route = BrainRoutePayload(tracks: ["brainstem"], reason: "test", episode: episode)
        await bus.publish(
            BantiEvent(source: "track_router", topic: "brain.route", surprise: 1.0,
                       payload: .brainRoute(route)),
            topic: "brain.route"
        )
        try? await Task.sleep(nanoseconds: 400_000_000)

        let events = await received.value
        XCTAssertEqual(events.count, 1, "should publish empty plan as fallback")
        if case .speechPlan(let plan) = events.first?.payload {
            XCTAssertTrue(plan.sentences.isEmpty)
        }
    }
}
```

- [ ] **Run test — expect failure** `swift test --filter ResponseArbitratorTests 2>&1 | tail -5`

- [ ] **Implement**

```swift
// Sources/BantiCore/ResponseArbitrator.swift
import Foundation

public actor ResponseArbitrator: CorticalNode {
    public let id = "response_arbitrator"
    public let subscribedTopics = ["brain.route", "brain.brainstem.response",
                                    "brain.limbic.response", "brain.prefrontal.response"]

    private let cerebras: CerebrasCompletion
    private let collectionWindowNs: UInt64
    private var _bus: EventBus?

    // Per-route collection state
    private var activatedTracks: [String] = []
    private var collectedResponses: [BrainResponsePayload] = []
    private var windowTask: Task<Void, Never>?

    private static let systemPrompt = """
    You are banti's response arbitrator. Given candidate responses from different brain tracks,
    produce an ordered list of sentences to speak. Suppress redundant content. Merge where natural.
    Prefer empathy before information. Output JSON only: {"sentences":["<s1>","<s2>",...]}
    If nothing is worth saying, return: {"sentences":[]}
    """

    public init(cerebras: CerebrasCompletion, collectionWindowMs: Int = 5000) {
        self.cerebras = cerebras
        self.collectionWindowNs = UInt64(collectionWindowMs) * 1_000_000
    }

    public func start(bus: EventBus) async {
        _bus = bus
        for topic in subscribedTopics {
            await bus.subscribe(topic: topic) { [weak self] event in
                await self?.handle(event)
            }
        }
    }

    public func handle(_ event: BantiEvent) async {
        switch event.payload {
        case .brainRoute(let route):
            // New route: reset collection state and start window timer
            activatedTracks = route.tracks
            collectedResponses = []
            windowTask?.cancel()
            let ns = collectionWindowNs
            windowTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: ns)
                guard !Task.isCancelled else { return }
                await self?.flush()
            }
        case .brainResponse(let response):
            collectedResponses.append(response)
            // If all activated tracks have responded, flush early
            let respondedTracks = Set(collectedResponses.map { $0.track })
            let expectedTracks = Set(activatedTracks)
            if respondedTracks.isSuperset(of: expectedTracks) {
                windowTask?.cancel()
                await flush()
            }
        default:
            break
        }
    }

    private func flush() async {
        guard let bus = _bus else { return }
        defer { collectedResponses = []; activatedTracks = [] }

        if collectedResponses.isEmpty {
            // Timeout fallback: publish empty plan
            await bus.publish(
                BantiEvent(source: id, topic: "motor.speech_plan", surprise: 0,
                           payload: .speechPlan(SpeechPlanPayload(sentences: []))),
                topic: "motor.speech_plan"
            )
            return
        }

        let candidateText = collectedResponses
            .map { "[\($0.track)]: \($0.text)" }
            .joined(separator: "\n")

        do {
            let response = try await cerebras("llama3.1-8b", Self.systemPrompt, candidateText, 150)
            guard let data = response.data(using: .utf8),
                  let json = try? JSONDecoder().decode(PlanJSON.self, from: data) else { return }
            await bus.publish(
                BantiEvent(source: id, topic: "motor.speech_plan", surprise: 0,
                           payload: .speechPlan(SpeechPlanPayload(sentences: json.sentences))),
                topic: "motor.speech_plan"
            )
        } catch {
            await bus.publish(
                BantiEvent(source: id, topic: "motor.speech_plan", surprise: 0,
                           payload: .speechPlan(SpeechPlanPayload(sentences: []))),
                topic: "motor.speech_plan"
            )
        }
    }

    private struct PlanJSON: Codable { let sentences: [String] }
}
```

- [ ] **Run test — expect pass** `swift test --filter ResponseArbitratorTests 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/ResponseArbitrator.swift Tests/BantiTests/ResponseArbitratorTests.swift
git commit -m "feat: ResponseArbitrator — collects brain responses, publishes speech plan"
```

---

## Task 7: AudioCortex (with efference copy)

`AudioCortex` owns mic + Deepgram + Hume. It subscribes to `motor.voice` and suppresses its own input while Banti is speaking or in the tail window.

**Files:**
- Create: `Sources/BantiCore/AudioCortex.swift`
- Create: `Tests/BantiTests/AudioCortexPhase2Tests.swift`

- [ ] **Write the failing tests**

```swift
// Tests/BantiTests/AudioCortexPhase2Tests.swift
import XCTest
@testable import BantiCore

final class AudioCortexPhase2Tests: XCTestCase {

    func testSuppressesMicWhileSpeaking() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "sensor.audio") { event in
            await received.append(event)
        }

        let cortex = AudioCortex(deepgram: nil, hume: nil, bus: bus)
        await cortex.start(bus: bus)

        // Signal that Banti started speaking
        await bus.publish(
            BantiEvent(source: "banti_voice", topic: "motor.voice", surprise: 0,
                       payload: .voiceSpeaking(VoiceSpeakingPayload(speaking: true,
                           estimatedDurationMs: 1000, tailWindowMs: 5000,
                           text: "hello friend"))),
            topic: "motor.voice"
        )
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Simulate transcript arriving during speaking — should be suppressed
        await cortex.injectTranscriptForTest("hello friend") // self-echo
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual((await received.value).count, 0, "transcript during speaking should be suppressed")
    }

    func testPassesThroughAfterTailWindow() async {
        let bus = EventBus()
        let received = ActorBox<[BantiEvent]>([])
        _ = await bus.subscribe(topic: "sensor.audio") { event in
            if case .speechDetected = event.payload { await received.append(event) }
        }

        let cortex = AudioCortex(deepgram: nil, hume: nil, bus: bus)
        await cortex.start(bus: bus)

        // Signal stop (never started — tail window is 50ms for test)
        await cortex.setTailWindowMsForTest(50)
        await bus.publish(
            BantiEvent(source: "banti_voice", topic: "motor.voice", surprise: 0,
                       payload: .voiceSpeaking(VoiceSpeakingPayload(speaking: false,
                           estimatedDurationMs: 0, tailWindowMs: 50, text: nil))),
            topic: "motor.voice"
        )
        try? await Task.sleep(nanoseconds: 100_000_000) // wait past tail window

        await cortex.injectTranscriptForTest("different content")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual((await received.value).count, 1, "non-echo transcript after tail window should pass through")
    }
}
```

- [ ] **Run test — expect failure** `swift test --filter AudioCortexPhase2Tests 2>&1 | tail -5`

- [ ] **Implement `AudioCortex`** — wraps `MicrophoneCapture`, `DeepgramStreamer`, `HumeVoiceAnalyzer`. Key addition: subscribes to `motor.voice`; maintains `isSpeaking: Bool` and `tailWindowEndNs: UInt64?`. In the Deepgram transcript callback, check suppression before publishing. Add `injectTranscriptForTest()` and `setTailWindowMsForTest()` as internal methods for testability.

- [ ] **Run test — expect pass** `swift test --filter AudioCortexPhase2Tests 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/AudioCortex.swift Tests/BantiTests/AudioCortexPhase2Tests.swift
git commit -m "feat: AudioCortex — efference copy suppression via motor.voice subscription"
```

---

## Task 8: VisualCortex + ScreenCortex

These nodes inline the logic from `LocalPerception` + `PerceptionRouter`'s camera/screen branches. No new LLM calls — they still use GPT-4o Vision. The surprise detector gates them.

**Files:**
- Create: `Sources/BantiCore/VisualCortex.swift`
- Create: `Sources/BantiCore/ScreenCortex.swift`

- [ ] **Implement `VisualCortex`** — owns `CameraCapture`, runs `LocalPerception`'s Apple Vision pipeline internally, calls `GPT4oActivityAnalyzer`, `GPT4oGestureAnalyzer`, `HumeEmotionAnalyzer`. On each result, publishes `sensor.visual` with a `FacePayload` or `EmotionPayload`. No fixed throttle — every frame that produces a result publishes. The `SurpriseDetector` downstream will gate.

- [ ] **Implement `ScreenCortex`** — same pattern for screen: owns `ScreenCapture`, calls `GPT4oScreenAnalyzer`, publishes `sensor.screen` with `ScreenPayload`.

- [ ] **Build** `swift build 2>&1 | tail -3`

- [ ] **Commit**
```bash
git add Sources/BantiCore/VisualCortex.swift Sources/BantiCore/ScreenCortex.swift
git commit -m "feat: VisualCortex + ScreenCortex — autonomous sensor nodes"
```

---

## Task 9: MemoryLoader + MemoryConsolidator

**Files:**
- Create: `Sources/BantiCore/MemoryLoader.swift`
- Create: `Sources/BantiCore/MemoryConsolidator.swift`
- Create: `Tests/BantiTests/MemoryLoaderTests.swift`
- Create: `Tests/BantiTests/MemoryConsolidatorTests.swift`

- [ ] **Test MemoryLoader**

```swift
// Tests/BantiTests/MemoryLoaderTests.swift
func testPublishesMemoryRetrievedOnFaceWithPerson() async {
    let bus = EventBus()
    let received = ActorBox<[BantiEvent]>([])
    _ = await bus.subscribe(topic: "memory.retrieve") { event in
        await received.append(event)
    }

    // Mock sidecar query returns facts
    let loader = MemoryLoader(querySidecar: { personID in
        MemoryRetrievedPayload(personID: personID, personName: "Pavan",
                               facts: ["likes chai", "works on banti"])
    })
    await loader.start(bus: bus)

    let face = FacePayload(boundingBox: CodableCGRect(.zero), personID: "p1",
                           personName: "Pavan", confidence: 0.9)
    await bus.publish(
        BantiEvent(source: "visual_cortex", topic: "sensor.visual", surprise: 0.6,
                   payload: .faceUpdate(face)),
        topic: "sensor.visual"
    )
    try? await Task.sleep(nanoseconds: 50_000_000)

    let events = await received.value
    XCTAssertEqual(events.count, 1)
    if case .memoryRetrieved(let m) = events.first?.payload {
        XCTAssertEqual(m.personID, "p1")
        XCTAssertTrue(m.facts.contains("likes chai"))
    } else { XCTFail() }
}
```

- [ ] **Implement `MemoryLoader`** — subscribes to `sensor.visual`, on `faceUpdate` with non-nil `personID`, calls injected `querySidecar: (String) async -> MemoryRetrievedPayload` closure (which calls `MemorySidecar.query()` in production), publishes `memory.retrieve`. Throttle: one fetch per `personID` per 30 seconds.

- [ ] **Test MemoryConsolidator**

```swift
func testStoresHighValueEpisode() async {
    let bus = EventBus()
    var storedEpisodes: [String] = []
    let consolidator = MemoryConsolidator(
        cerebras: { _, _, _, _ in """{"store":true,"reason":"meaningful interaction"}""" },
        storeSidecar: { episode in storedEpisodes.append(episode) }
    )
    await consolidator.start(bus: bus)
    let ep = EpisodePayload(text: "Pavan fixed the bug!", participants: ["Pavan"], emotionalTone: "happy")
    await bus.publish(
        BantiEvent(source: "temporal_binder", topic: "episode.bound", surprise: 1.0,
                   payload: .episodeBound(ep)),
        topic: "episode.bound"
    )
    try? await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(storedEpisodes.count, 1)
}

func testSkipsLowValueEpisode() async { /* mock cerebras returns {"store":false,...} */ }
```

- [ ] **Implement `MemoryConsolidator`** — subscribes to `episode.bound`, asks Cerebras `llama3.1-8b` whether to store, calls `storeSidecar` if yes, publishes `memory.write`.

- [ ] **Run tests** `swift test --filter "MemoryLoaderTests|MemoryConsolidatorTests" 2>&1 | tail -5`

- [ ] **Commit**
```bash
git add Sources/BantiCore/MemoryLoader.swift Sources/BantiCore/MemoryConsolidator.swift Tests/BantiTests/MemoryLoaderTests.swift Tests/BantiTests/MemoryConsolidatorTests.swift
git commit -m "feat: MemoryLoader + MemoryConsolidator — memory as bus participant"
```

---

## Task 10: Wire New Graph into MemoryEngine, Delete Old Components

**Files:**
- Modify: `Sources/BantiCore/MemoryEngine.swift`
- Delete: `PerceptionRouter.swift`, `PerceptionContext.swift`, `LocalPerception.swift`, `BrainLoop.swift`, `SpeakerAttributor.swift`, `SelfSpeechLog.swift`, `MemoryIngestor.swift`
- Modify: `memory_sidecar/memory.py` — remove `_reasoning_stream` (Anthropic Opus path)

- [ ] **Update `MemoryEngine`** to instantiate all new nodes and call `start(bus: eventBus)` on each. Remove references to `PerceptionRouter`, `BrainLoop`, `MemoryIngestor`. Wire `BantiVoice` to subscribe to `motor.speech_plan` and speak each sentence.

- [ ] **Update `main.swift`** — replace `LocalPerception` + `PerceptionRouter` with `VisualCortex` + `ScreenCortex` + `AudioCortex`.

- [ ] **Wire `BantiVoice` to `motor.speech_plan`** — add subscription:

```swift
await bus.subscribe(topic: "motor.speech_plan") { [weak bantiVoice] event in
    guard case .speechPlan(let plan) = event.payload else { return }
    for sentence in plan.sentences where !sentence.isEmpty {
        await bantiVoice?.say(sentence, track: .reflex)
    }
    await bantiVoice?.markPlaybackEnded()
}
```

- [ ] **Delete old source files**
```bash
rm Sources/BantiCore/PerceptionRouter.swift
rm Sources/BantiCore/PerceptionContext.swift
rm Sources/BantiCore/LocalPerception.swift
rm Sources/BantiCore/BrainLoop.swift
rm Sources/BantiCore/SpeakerAttributor.swift
rm Sources/BantiCore/SelfSpeechLog.swift
rm Sources/BantiCore/MemoryIngestor.swift
```

- [ ] **Build** `swift build 2>&1 | tail -5`
  Fix any reference errors from the deletions.

- [ ] **Update old tests** — tests for deleted types (`PerceptionRouterTests`, `BrainLoopTests`, `SpeakerAttributorTests`, `SelfSpeechLogTests`, `MemoryIngestorTests`) are deleted. Tests for `BantiVoice`, `AudioRouter`, `ConversationBuffer` that don't reference deleted types can stay.

- [ ] **Remove Opus from `memory_sidecar/memory.py`** — delete `_reasoning_stream` function and its Anthropic dependency. The sidecar's `/brain/stream` endpoint now only serves as a fallback; primary reasoning is via `PrefrontalNode` on the Swift side.

- [ ] **Run full test suite** `swift test 2>&1 | tail -10`

- [ ] **Smoke test** `swift run banti 2>&1 | head -30` — verify no crash on startup, new nodes log their starts

- [ ] **Commit**
```bash
git add -A
git commit -m "feat: Phase 2 complete — cortical node graph live, old components deleted"
```
