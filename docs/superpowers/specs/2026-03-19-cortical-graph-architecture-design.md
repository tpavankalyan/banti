# Cortical Graph Architecture Design

**Date:** 2026-03-19
**Status:** Approved
**Approach:** Option B — three-phase migration

---

## Overview

Replace banti's current hub-and-spoke perception/brain architecture with a decentralised cortical graph: an in-process event bus connecting autonomous sensor cortices, cognitive gate nodes, parallel brain tracks, and memory participants. Every LLM node uses Cerebras (Llama). ASR (Deepgram), TTS (Cartesia), Hume voice emotion, GPT-4o Vision, and Apple Vision are unchanged.

The migration is split into three independently shippable phases so existing tests pass at every checkpoint.

---

## Phase 1 — Infrastructure

### EventBus

A single `actor EventBus` replaces all direct method calls between components.

```swift
actor EventBus {
    func publish(_ event: BantiEvent, topic: String)
    func subscribe(topic: String, handler: @escaping (BantiEvent) -> Void) -> SubscriptionID
    func unsubscribe(_ id: SubscriptionID)
}
```

- Subscriber map: `[String: [(SubscriptionID, (BantiEvent) -> Void)]]`
- Topic matching: exact (`sensor.visual`) and prefix wildcard (`sensor.*`)
- Publish is synchronous within the actor; subscribers called in registration order
- Zero serialisation overhead — Swift structs passed by value

### BantiEvent

```swift
struct BantiEvent: Codable, Sendable {
    let id: UUID
    let source: String       // "visual_cortex", "audio_cortex", etc.
    let topic: String        // "sensor.visual"
    let timestampNs: UInt64  // mach_absolute_time() converted to nanoseconds
    let surprise: Float      // 0–1, set by source or SurpriseDetector
    let payload: EventPayload
}

enum EventPayload: Codable, Sendable {
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
```

### Topic Hierarchy

```
sensor.audio          — speech detected, transcript, sound events
sensor.visual         — face, activity, gesture, emotion from camera
sensor.screen         — OCR, screen interpretation
sensor.sound          — non-speech sound classification

gate.surprise         — filtered high-surprise events forwarded downstream
gate.attention        — (future) attention gate output

episode.bound         — fused multi-modal episode from TemporalBinder

brain.route           — track activation list from TrackRouter
brain.brainstem.response
brain.limbic.response
brain.prefrontal.response

motor.speech_plan     — ordered sentence list from ResponseArbitrator
motor.voice           — efference copy: banti speaking start/end

memory.retrieve       — person context loaded from mem0/Graphiti
memory.write          — episode stored to long-term memory
```

### CorticalNode Protocol

```swift
protocol CorticalNode: Actor {
    var id: String { get }
    var subscribedTopics: [String] { get }
    func start(bus: EventBus) async
    func handle(_ event: BantiEvent) async
}
```

Every node — sensor cortices, gate nodes, brain tracks, memory nodes, motor nodes — implements this protocol. `start()` registers subscriptions and begins the node's internal loop. `handle()` processes incoming events and calls `bus.publish()` for outputs.

### Phase 1 Scope

Existing `PerceptionRouter`, `BrainLoop`, `MemoryEngine`, and `AudioRouter` are **adapted** — they subscribe/publish via `EventBus` but keep their internal logic unchanged. No new LLM nodes. All existing tests pass; only wiring changes.

`main.swift` creates one shared `EventBus` and passes it to every component.

`ContextAggregator` is introduced: a thin node that subscribes to `sensor.*` and maintains last-known field values, providing `snapshotJSON()` for the Python sidecar. This extracts the snapshot responsibility out of `PerceptionContext`.

---

## Phase 2 — New Nodes

### Kill PerceptionRouter → Autonomous Sensor Cortices

`PerceptionRouter` is deleted. Three independent `CorticalNode` actors take its place:

| Node | Owns | Publishes | Cloud calls |
|---|---|---|---|
| `VisualCortex` | `CameraCapture` + Apple Vision | `sensor.visual` | GPT-4o (activity, gesture, emotion) |
| `ScreenCortex` | `ScreenCapture` + Apple Vision | `sensor.screen` | GPT-4o (screen interpretation) |
| `AudioCortex` | `MicrophoneCapture` + Deepgram + Hume | `sensor.audio` | Deepgram (ASR), Hume (voice emotion) |

Fixed throttles (`shouldFire(analyzerName:throttleSeconds:)`) are removed. Publish frequency is governed by the surprise detector.

`PerceptionContext` flat state bag is removed. State is carried in event payloads. `ContextAggregator` (introduced in Phase 1) becomes the sole keeper of last-known state for the sidecar.

### SurpriseDetector (new Cerebras node)

Subscribes to raw text descriptions from all three cortices. For each incoming description, sends a short prompt to **Cerebras Llama 3.1-8b**: "did anything meaningfully change since last publish?" Returns `surprise: Float` 0–1.

- Threshold `>= 0.3`: attach score to event and forward to `gate.surprise`
- Below threshold: drop

For `VisualCortex`, the input is the GPT-4o text description (not pixels). For `AudioCortex`, it is the transcript or sound label. For `ScreenCortex`, the GPT-4o interpretation text.

Replaces all fixed `throttleSeconds` values in `PerceptionRouter`.

### TemporalBinder (new Cerebras node)

Subscribes to `gate.surprise`. Accumulates events within a **500ms window** using a resetting timer. When the window closes, sends all accumulated event descriptions to **Cerebras Llama 3.1-8b** with a fusion prompt.

Output: publishes `episode.bound` with:
- `text`: natural-language episode description
- `participants`: list of people detected
- `emotionalTone`: dominant tone string
- `timestampNs`: timestamp of earliest event in window

### TrackRouter (new Cerebras node)

Subscribes to `episode.bound`. Sends the episode text to **Cerebras Llama 3.1-8b** with a prompt asking which tracks to activate and why.

Output: publishes `brain.route` with:
```swift
struct BrainRoutePayload: Codable, Sendable {
    let tracks: [String]   // e.g. ["brainstem", "prefrontal"]
    let reason: String
    let episode: EpisodePayload
}
```

### Brain Tracks (all Cerebras)

Three parallel `CorticalNode` actors replace the current two-track `BrainLoop`:

| Node | Topic | Model | Timeout | Role |
|---|---|---|---|---|
| `BrainstemNode` | `brain.brainstem.response` | Cerebras Llama 3.1-8b | 3s | Instant reflex, 1–2 sentences |
| `LimbicNode` | `brain.limbic.response` | Cerebras Llama 3.1-8b | 5s | Emotional response using Hume data |
| `PrefrontalNode` | `brain.prefrontal.response` | Cerebras Llama 3.1-70b | 12s | Deep reasoning + memory context |

All three subscribe to `brain.route`. Each activates only if its track name appears in the route payload. They fire in parallel via Swift structured concurrency (`TaskGroup`). Each streams tokens from Cerebras and publishes a `brainResponse` event when the stream closes.

`BrainLoop` is deleted. `_reflex_stream` becomes `BrainstemNode`. `_reasoning_stream` (Opus) becomes `PrefrontalNode` (Cerebras 70b).

### ResponseArbitrator (new Cerebras node)

Subscribes to `brain.brainstem.response`, `brain.limbic.response`, `brain.prefrontal.response`. Collects responses: waits for brainstem (minimum), up to 5s for others. Sends all candidates to **Cerebras Llama 3.1-8b** with a prompt to order, suppress redundant, or merge as appropriate.

Output: publishes `motor.speech_plan` with an ordered list of sentences.

`BantiVoice` subscribes to `motor.speech_plan` and speaks the sentences in order (replacing direct calls from `BrainLoop`).

### Efference Copy

When `BantiVoice` begins speaking, it publishes `motor.voice` with `{ speaking: true, estimatedDurationMs: N }`. `AudioCortex` subscribes to `motor.voice` and suppresses its own mic input during that window.

Replaces `SpeakerAttributor`, `SelfSpeechLog`, and `BantiVoice.suppressSelfEcho(in:)`.

### Memory as Bus Participant

**MemoryLoader** (new node):
- Subscribes to `sensor.visual` events that contain a face identity
- On face identified: fetches from mem0/Graphiti via Python sidecar, publishes `memory.retrieve` with person context
- `PrefrontalNode` subscribes to `memory.retrieve` and includes it in its prompt context

**MemoryConsolidator** (new Cerebras node):
- Subscribes to `episode.bound`
- Sends episode to **Cerebras Llama 3.1-8b** with prompt: "is this worth storing long-term?"
- If yes: writes to Graphiti/mem0 via sidecar, publishes `memory.write`
- Replaces `MemoryIngestor` periodic snapshot ingestion

---

## Phase 3 — Plumbing + Observability

### Unix Domain Socket (Python Bridge)

FastAPI HTTP sidecar replaced with a Unix domain socket server.

- **Socket path:** `/tmp/banti_memory.sock`
- **Serialisation:** `msgpack` with 4-byte length-prefix framing
- **Python side:** raw `socket` module — no FastAPI, no uvicorn, no HTTP overhead
- **Swift side:** `MemorySidecar` actor rewritten to use `NWConnection` with `.unix(path:)`
- **Expected latency:** ~0.5ms vs ~5–10ms for HTTP

`MemorySidecar` public API changes from URL-based to typed async methods:
```swift
func identify(face jpegData: Data) async -> PersonIdentity
func identify(voice pcmData: Data) async -> PersonIdentity
func store(episode: String, timestamp: Date) async
func query(_ q: String) async -> [String]
func reflect(snapshots: [String]) async -> String
```

The sidecar is still launched as a subprocess from `main.swift` via `Process`. Health check becomes a socket ping.

### Ring Buffer for Working Memory

`ConversationBuffer` rewritten as a fixed-capacity ring buffer:
- Capacity: 60 turns (~30s at normal conversation pace)
- O(1) push, no GC pressure, fixed allocation
- `recentTurns(limit:)` returns last N in chronological order

Replaces the current unbounded `[ConversationTurn]` array.

### mach_absolute_time() Timestamps

`BantiEvent.timestampNs` uses `mach_absolute_time()` converted to nanoseconds via `mach_timebase_info`. `Date()` removed from all event envelopes. `TemporalBinder` uses these timestamps for 500ms window arithmetic — sub-millisecond accuracy.

### YAML Config

`NodeConfig.yaml` at project root declares every node:

```yaml
nodes:
  visual_cortex:
    subscribes: [sensor.camera.raw]
    publishes: [sensor.visual]
    prompt_file: prompts/visual_cortex.md

  surprise_detector:
    model: cerebras://llama3.1-8b
    subscribes: [sensor.*]
    publishes: [gate.surprise]
    prompt_file: prompts/surprise_detector.md

  temporal_binder:
    model: cerebras://llama3.1-8b
    subscribes: [gate.surprise]
    publishes: [episode.bound]
    prompt_file: prompts/temporal_binder.md
    window_ms: 500
```

`ConfigLoader` reads this at startup and hot-reloads on `SIGHUP`. System prompts live in `prompts/<node>.md` — swap a prompt without recompiling.

### BrainMonitor

A lightweight SwiftUI debug panel, opt-in via `--monitor` launch flag.

- Implemented as a `CorticalNode` subscribing to all topics (`*`)
- Pipes events into a `@Published [MonitorEvent]` array
- Renders a scrolling `List`: source, topic, timestamp, payload summary, per-node latency
- In-process subscriber — no separate process, no network

---

## Deletion Table

| Deleted | Replaced by |
|---|---|
| `PerceptionRouter` | `VisualCortex`, `ScreenCortex`, `AudioCortex` |
| `PerceptionContext` flat bag | `ContextAggregator` + typed event payloads |
| `BrainLoop` (2 tracks) | `TrackRouter` + 3 track nodes + `ResponseArbitrator` |
| `MemoryIngestor` periodic snapshot | `MemoryConsolidator` episode-driven node |
| `SpeakerAttributor` / `SelfSpeechLog` | Efference copy via `motor.voice` event |
| FastAPI HTTP sidecar | Unix domain socket + msgpack |
| Fixed throttles | `SurpriseDetector` node |
| `_reasoning_stream` using Anthropic Opus | `PrefrontalNode` using Cerebras 70b |

## Unchanged

- Deepgram ASR
- Cartesia TTS
- Hume voice emotion
- GPT-4o Vision (activity, gesture, screen)
- Apple Vision framework (face detection, pose, OCR)
- Face identity store (SQLite)
- mem0 + Graphiti memory backends
