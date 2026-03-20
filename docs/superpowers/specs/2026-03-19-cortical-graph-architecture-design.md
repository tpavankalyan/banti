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

### BantiClock

A shared clock utility introduced in Phase 1 and used by all subsequent phases. Defined once; all nodes call this, never `mach_absolute_time()` directly.

```swift
enum BantiClock {
    static func nowNs() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return mach_absolute_time() * UInt64(info.numer) / UInt64(info.denom)
    }
}
```

`BantiEvent.timestampNs` is always populated by calling `BantiClock.nowNs()`. The conversion from hardware ticks to nanoseconds is done at call time, so all arithmetic (including the TemporalBinder 500ms window) works correctly across all Mac hardware timebase ratios.

### EventBus

A single `actor EventBus` replaces all direct method calls between components.

```swift
actor EventBus {
    func publish(_ event: BantiEvent, topic: String)
    func subscribe(topic: String, handler: @escaping @Sendable (BantiEvent) async -> Void) -> SubscriptionID
    func unsubscribe(_ id: SubscriptionID)
}
```

- Subscriber map: `[String: [(SubscriptionID, @Sendable (BantiEvent) async -> Void)]]`
- Topic matching: exact (`sensor.visual`), prefix wildcard (`sensor.*`), and match-all (`*`)
- **Publish dispatches each subscriber via `Task { await handler(event) }`** — the EventBus actor releases isolation before invoking subscriber code. This prevents actor deadlocks when subscribers are themselves actors. Publish is fire-and-forget; order of delivery is not guaranteed.
- `BantiEvent` is `Sendable`; all payload types conform to `Sendable`

### BantiEvent

```swift
struct BantiEvent: Codable, Sendable {
    let id: UUID
    let source: String       // "visual_cortex", "audio_cortex", etc.
    let topic: String        // "sensor.visual"
    let timestampNs: UInt64  // BantiClock.nowNs() — nanoseconds, not hardware ticks
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

`*` is a valid subscription topic meaning "all events on all topics." Used by BrainMonitor only.

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

Existing `PerceptionRouter`, `BrainLoop`, `MemoryEngine`, and `AudioRouter` are **adapted** — they subscribe/publish via `EventBus` but keep their internal logic unchanged. No new LLM nodes.

**Test compatibility:** All existing direct-call APIs are preserved in Phase 1 as compatibility shims alongside the new bus wiring. For example, `PerceptionRouter.dispatch(jpegData:source:events:)` still exists and still works; Phase 1 just adds `bus.publish()` calls at the end of it. `BrainLoop.onFinalTranscript(_:)` still exists. Existing XCTests for these types continue to call methods directly and continue to pass. The shims are removed in Phase 2 when the types are replaced.

`main.swift` creates one shared `EventBus` and passes it to every component.

`ContextAggregator` is introduced: a thin node that subscribes to `sensor.*` and maintains last-known field values, providing `snapshotJSON()` for the Python sidecar. This extracts the snapshot responsibility out of `PerceptionContext`, leaving `PerceptionContext` to be deleted in Phase 2.

`snapshotJSON()` is called by `BrainLoop` (and later `PrefrontalNode`) on the same polling interval as today. In Phase 2, `PrefrontalNode` uses `episode.bound` text and the `memory.retrieve` cache instead of `snapshotJSON()` — at that point `ContextAggregator` becomes a compatibility shim used only by `SelfModel`'s reflection loop. In Phase 3, `SelfModel` is updated to receive context via `episode.bound` events directly, and `ContextAggregator` is deleted.

---

## Phase 2 — New Nodes

### Kill PerceptionRouter → Autonomous Sensor Cortices

`PerceptionRouter` is deleted. Three independent `CorticalNode` actors take its place:

| Node | Owns | Publishes | Cloud calls |
|---|---|---|---|
| `VisualCortex` | `CameraCapture` + `LocalPerception` (Apple Vision) | `sensor.visual` | GPT-4o (activity, gesture, face emotion) |
| `ScreenCortex` | `ScreenCapture` + `LocalPerception` (Apple Vision OCR) | `sensor.screen` | GPT-4o (screen interpretation) |
| `AudioCortex` | `MicrophoneCapture` + Deepgram + Hume | `sensor.audio` | Deepgram (ASR), Hume (voice emotion) |

**`LocalPerception` fate:** `LocalPerception` is inlined as a private dependency inside `VisualCortex` and `ScreenCortex` respectively. The `PerceptionDispatcher` protocol and `LocalPerception`'s `frameProcessor` injection point are removed; the cortex actors own the full stack from frame capture to event publish. `LocalPerception.swift` is deleted; its Vision analysis code lives in the cortex actors.

Fixed throttles (`shouldFire(analyzerName:throttleSeconds:)`) are removed. Publish frequency is governed by the surprise detector.

`PerceptionContext` flat state bag is deleted. State is carried in event payloads. `ContextAggregator` (introduced in Phase 1) becomes the sole keeper of last-known state for the sidecar.

### SurpriseDetector (new Cerebras node)

Subscribes to raw text descriptions from all three cortices. For each incoming description, sends a short prompt to **Cerebras `llama3.1-8b`**: "did anything meaningfully change since last publish?" Returns `surprise: Float` 0–1.

- Threshold `>= 0.3`: attach score to event and forward to `gate.surprise`
- Below threshold: drop

For `VisualCortex`, the input is the GPT-4o text description (not pixels). For `AudioCortex`, it is the transcript or sound label. For `ScreenCortex`, the GPT-4o interpretation text.

Replaces all fixed `throttleSeconds` values in `PerceptionRouter`.

### TemporalBinder (new Cerebras node)

Subscribes to `gate.surprise`. Accumulates events using **debounce semantics**: each new incoming `gate.surprise` event resets a 500ms timer. When the timer fires without a new event arriving (i.e., 500ms of silence after the last event), the window closes and the accumulated events are fused.

The binder sends all accumulated event descriptions to **Cerebras `llama3.1-8b`** with a fusion prompt.

Output: publishes `episode.bound` with:
- `text`: natural-language episode description
- `participants`: list of people detected
- `emotionalTone`: dominant tone string
- `timestampNs`: `BantiClock.nowNs()` of the earliest event in the window

### TrackRouter (new Cerebras node)

Subscribes to `episode.bound`. Sends the episode text to **Cerebras `llama3.1-8b`** with a prompt asking which tracks to activate and why.

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
| `BrainstemNode` | `brain.brainstem.response` | Cerebras `llama3.1-8b` | 3s | Instant reflex, 1–2 sentences |
| `LimbicNode` | `brain.limbic.response` | Cerebras `llama3.1-8b` | 5s | Emotional response using Hume data |
| `PrefrontalNode` | `brain.prefrontal.response` | Cerebras `llama3.1-70b` | 12s | Deep reasoning + memory context |

All three subscribe to `brain.route`. Each activates only if its track name appears in the route payload. They fire in parallel via Swift structured concurrency (`TaskGroup`). Each streams tokens from Cerebras and publishes a `brainResponse` event when the stream closes.

**Cerebras model identifier strings** (matching the Cerebras API `model` field):
- Fast nodes: `"llama3.1-8b"`
- Prefrontal: `"llama-3.3-70b"` (Cerebras 70b offering as of 2026-03)

`BrainLoop` is deleted. `_reflex_stream` becomes `BrainstemNode`. `_reasoning_stream` (Opus) becomes `PrefrontalNode` (Cerebras 70b).

### ResponseArbitrator (new Cerebras node)

Subscribes to **`brain.route`** and all three response topics (`brain.brainstem.response`, `brain.limbic.response`, `brain.prefrontal.response`). The `brain.route` subscription tells it which tracks were activated for the current episode, enabling the correct collection window logic. Collection window:

- If `brainstem` is in the activated tracks: waits up to 3s for brainstem response, then up to 2s more for others (5s total from route publish)
- If `brainstem` is NOT in the activated tracks: waits up to 5s for whichever tracks were activated
- **Fallback:** if no response arrives within the window (all activated tracks timed out, errored, or were never activated), `ResponseArbitrator` publishes an empty `motor.speech_plan` — no speech. Silence is always safe.

Once responses are collected, sends all candidates to **Cerebras `llama3.1-8b`** to order, suppress redundant, or merge.

Output: publishes `motor.speech_plan` with an ordered list of sentences.

`BantiVoice` subscribes to `motor.speech_plan` and speaks the sentences in order (replacing direct calls from `BrainLoop`).

### Efference Copy + Tail Window

When `BantiVoice` begins speaking, it publishes `motor.voice` with `{ speaking: true, estimatedDurationMs: N }`. When playback ends, it publishes `motor.voice` with `{ speaking: false, tailWindowMs: 5000 }`.

`AudioCortex` subscribes to `motor.voice` and:
- While `speaking: true`: suppresses mic input entirely
- After `speaking: false`: starts a 5-second tail window during which transcripts are checked against the last spoken text (same logic as the current `SelfSpeechLog.isSelfEcho()`) before being forwarded downstream

`SpeakerAttributor`, `SelfSpeechLog`, and `BantiVoice.suppressSelfEcho(in:)` are deleted. The tail-window logic moves into `AudioCortex`.

### Memory as Bus Participant

**MemoryLoader** (new node):
- Subscribes to `sensor.visual` events containing a face identity
- On face identified: fetches from mem0/Graphiti via the Python sidecar (HTTP in Phase 2, socket in Phase 3 — see Phase 3 migration note), publishes `memory.retrieve` with person context including a `personId` field matching the face identity

**`PrefrontalNode` ↔ `MemoryLoader` correlation model:**
`PrefrontalNode` subscribes to `memory.retrieve` and maintains a `[String: MemoryRetrievedPayload]` cache keyed by `personId`. When processing a `brain.route` event, it reads person IDs from `episode.participants` and looks them up in the cache. It uses the most recently received `memory.retrieve` for each participant, provided it arrived within the last **30 seconds**. Cache entries older than 30s are considered stale and ignored. This means `MemoryLoader` should publish proactively on face detection (not wait for a route event), so context is ready before `PrefrontalNode` needs it.

**MemoryConsolidator** (new Cerebras node):
- Subscribes to `episode.bound`
- Sends episode to **Cerebras `llama3.1-8b`** with prompt: "is this worth storing long-term?"
- If yes: writes to Graphiti/mem0 via sidecar, publishes `memory.write`
- Replaces `MemoryIngestor` periodic snapshot ingestion

### SelfModel and ProactiveIntroducer

- **`SelfModel`** (10-minute reflection loop): survives Phase 2 unchanged. It is a standalone actor in `MemoryEngine` and has no dependency on `PerceptionRouter` or `BrainLoop`. It continues calling `/memory/reflect` on the sidecar.
- **`ProactiveIntroducer`**: survives Phase 2 unchanged. Its "unknown person present > 30s" logic is currently triggered from `BrainLoop.pollEvents()`. In Phase 2, `TrackRouter` takes over this responsibility: it subscribes to **both `episode.bound` and `sensor.visual`**. The `sensor.visual` subscription lets `TrackRouter` track how long an unknown person has been visible and fire `brain.route` with `["brainstem"]` after 30s without a prior greeting.

---

## Phase 3 — Plumbing + Observability

### Unix Domain Socket (Python Bridge)

FastAPI HTTP sidecar replaced with a Unix domain socket server.

- **Socket path:** `/tmp/banti_memory.sock`
- **Serialisation:** `msgpack` with 4-byte big-endian length-prefix framing (request) + same framing (response)
- **Python side:** raw `socket` module, `msgpack` library — FastAPI and uvicorn are removed
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

**Phase 2 → Phase 3 migration for `MemoryLoader`:** In Phase 2, `MemoryLoader` calls the existing HTTP `MemorySidecar` methods. In Phase 3, it migrates to the new typed socket API. The Phase 3 task explicitly includes updating `MemoryLoader` to use the new API.

The sidecar is still launched as a subprocess from `main.swift` via `Process`. Health check becomes a socket ping.

### Ring Buffer for Working Memory

`ConversationBuffer` rewritten as a fixed-capacity ring buffer:
- **Capacity: 60 turns** (chosen to cover ~5 minutes of conversation at ~1 turn per 5s; existing callers use `recentTurns(limit: 10)` which is unaffected by the backing capacity)
- O(1) push, no GC pressure, fixed allocation
- `recentTurns(limit:)` returns last N in chronological order
- Current `maxTurns = 30` is replaced by `capacity = 60`; no callers need updating since `limit:` is always ≤ 30

### BantiClock (Phase 3 reminder)

`BantiClock` is introduced in Phase 1 but used for all timestamp arithmetic in Phase 2 and 3. No Phase 3 work needed here beyond verifying all nodes call `BantiClock.nowNs()`.

### YAML Config

`NodeConfig.yaml` at project root declares every node:

```yaml
nodes:
  visual_cortex:
    # VisualCortex receives frames from CameraCapture directly (not via bus)
    # subscribes is empty — sensor cortices are bus publishers, not subscribers
    publishes: [sensor.visual]
    prompt_file: prompts/visual_cortex.md

  surprise_detector:
    model: llama3.1-8b          # Cerebras model field value
    subscribes: [sensor.*]
    publishes: [gate.surprise]
    prompt_file: prompts/surprise_detector.md

  temporal_binder:
    model: llama3.1-8b
    subscribes: [gate.surprise]
    publishes: [episode.bound]
    prompt_file: prompts/temporal_binder.md
    window_ms: 500              # debounce window

  track_router:
    model: llama3.1-8b
    subscribes: [episode.bound, sensor.visual]   # sensor.visual for ProactiveIntroducer unknown-person logic
    publishes: [brain.route]
    prompt_file: prompts/track_router.md

  brainstem:
    model: llama3.1-8b
    subscribes: [brain.route]
    publishes: [brain.brainstem.response]
    prompt_file: prompts/brainstem.md
    timeout_s: 3

  limbic:
    model: llama3.1-8b
    subscribes: [brain.route]
    publishes: [brain.limbic.response]
    prompt_file: prompts/limbic.md
    timeout_s: 5

  prefrontal:
    model: llama-3.3-70b        # Cerebras 70b model field value
    subscribes: [brain.route, memory.retrieve]
    publishes: [brain.prefrontal.response]
    prompt_file: prompts/prefrontal.md
    timeout_s: 12

  response_arbitrator:
    model: llama3.1-8b
    subscribes: [brain.route, brain.brainstem.response, brain.limbic.response, brain.prefrontal.response]
    publishes: [motor.speech_plan]
    prompt_file: prompts/response_arbitrator.md

  memory_consolidator:
    model: llama3.1-8b
    subscribes: [episode.bound]
    publishes: [memory.write]
    prompt_file: prompts/memory_consolidator.md
```

`ConfigLoader` reads this at startup and hot-reloads on `SIGHUP`. System prompts live in `prompts/<node>.md` — swap a prompt without recompiling.

**Sensor cortices** (`visual_cortex`, `screen_cortex`, `audio_cortex`) receive input from hardware capture layers directly, not from the bus. Their `subscribes` field is empty or omitted in YAML; they are bus publishers only.

### BrainMonitor

A lightweight SwiftUI debug panel, opt-in via `--monitor` launch flag.

- Implemented as a `CorticalNode` subscribing to `*` (all topics — explicitly supported by EventBus as a special match-all case, not a prefix wildcard)
- Pipes events into a `@Published [MonitorEvent]` array
- Renders a scrolling `List`: source, topic, timestamp (formatted from `timestampNs`), payload summary, per-node latency (difference between episode `timestampNs` and response `timestampNs`)
- In-process subscriber — no separate process, no network

---

## Deletion Table

| Deleted | Replaced by |
|---|---|
| `PerceptionRouter` | `VisualCortex`, `ScreenCortex`, `AudioCortex` |
| `LocalPerception` / `PerceptionDispatcher` | Inlined into `VisualCortex` and `ScreenCortex` |
| `PerceptionContext` flat bag | `ContextAggregator` + typed event payloads |
| `BrainLoop` (2 tracks) | `TrackRouter` + 3 track nodes + `ResponseArbitrator` |
| `MemoryIngestor` periodic snapshot | `MemoryConsolidator` episode-driven node |
| `SpeakerAttributor` / `SelfSpeechLog` | Efference copy + tail window in `AudioCortex` |
| `BantiVoice.suppressSelfEcho(in:)` | Efference copy via `motor.voice` event |
| FastAPI HTTP sidecar | Unix domain socket + msgpack |
| Fixed throttles | `SurpriseDetector` node |
| `_reasoning_stream` (Anthropic Opus) | `PrefrontalNode` (Cerebras `llama-3.3-70b`) |

## Unchanged

- Deepgram ASR
- Cartesia TTS
- Hume voice emotion API
- GPT-4o Vision (activity, gesture, screen interpretation)
- Apple Vision framework (face detection, pose, OCR)
- Face identity store (SQLite)
- mem0 + Graphiti memory backends
- `SelfModel` (reflection loop)
- `ProactiveIntroducer` (unknown-person greeting logic, rewired to `TrackRouter` subscription in Phase 2)
