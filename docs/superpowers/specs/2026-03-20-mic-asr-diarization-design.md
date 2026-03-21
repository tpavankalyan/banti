# Microphone ASR + Speaker Diarization — Design Spec

**Date:** 2026-03-20  
**Status:** Draft (spec); **implementation** in repo extends beyond original V1 scope — see §13.  
**Module:** Perception — Microphone + Deepgram ASR (+ optional Brain / Speech loop in app)  
**Target:** macOS 14+ (Sonoma), Swift 5.9+, Xcode project (`.xcodeproj`)

## 1. Goal

Build the first perception module for Banti: a macOS app that continuously captures microphone audio, streams it to Deepgram for real-time ASR with speaker diarization, and displays a live transcript with speaker labels in a SwiftUI interface.

The architecture must support adding many future perception modules (system audio, brain, communication channels) without modifying existing code.

## 2. Architecture

### 2.1 Core Model

Every supervised module is a Swift `actor` conforming to a shared **`BantiModule`** protocol (formerly described here as `PerceptionModule`; same lifecycle shape). Modules never import each other — they communicate exclusively through typed events on an `EventHubActor`. Event payloads still conform to **`PerceptionEvent`** (name retained for historical reasons).

### 2.2 Runtime Infrastructure

These are **infrastructure actors** — they are not `BantiModule` conformers and are not supervised. They are initialized at app launch before the supervisor starts.

| Actor | Responsibility |
|---|---|
| `EventHubActor` | Typed pub/sub for all cross-module messages. Initialized first, injected into supervisor and all modules. |
| `ModuleSupervisorActor` | Lifecycle management, dependency ordering, restart policies. Polls `health()` on registered modules and publishes `ModuleStatusEvent` on transitions. |
| `ConfigActor` | Runtime configuration access. Parses `.env` with a built-in key=value parser (ignores `export` prefix, `#` comments, blank lines). |
| `StateRegistryActor` | Module status snapshots, metrics, last-error tracking for UI/ops. |

### 2.3 V1 Perception Modules

These conform to `BantiModule` and are managed by the supervisor.

| Actor | Role |
|---|---|
| `MicrophoneCaptureActor` | Captures PCM audio frames from hardware mic via AVAudioEngine |
| `DeepgramStreamingActor` | Streams audio over WebSocket to Deepgram, receives transcript JSON |
| `TranscriptProjectionActor` | Merges partial results, produces finalized transcript segments |

### 2.4 Supporting Components (not supervised `BantiModule`s)

| Component | Role |
|---|---|
| `TranscriptViewModel` | `@MainActor ObservableObject` — subscribes to `TranscriptSegmentEvent` via EventHub and drives SwiftUI. Not supervisor-managed. |

### 2.5 Extensibility Path

New modules only need:
1. `BantiModule` protocol conformance
2. Event contract declarations (new event types in `Core/Events/`)
3. Registration with `ModuleSupervisorActor`

Existing modules remain untouched unless event schemas change.

## 3. Component Interfaces

### 3.1 BantiModule Protocol (supervised modules)

```swift
protocol BantiModule: Actor {
    var id: ModuleID { get }
    var capabilities: Set<Capability> { get }
    func start() async throws
    func stop() async
    func health() async -> ModuleHealth
}
```

`ModuleID`: a `struct` wrapping a `String` identifier (e.g. `"mic-capture"`, `"deepgram-asr"`).

`Capability`: an extensible `struct` wrapping a `String` (e.g. `"audio-capture"`, `"transcription"`, `"diarization"`). Not an enum, so new modules can declare new capabilities without modifying Core.

`ModuleHealth`: `.healthy`, `.degraded(reason: String)`, `.failed(error: Error)`.

### 3.2 PerceptionEvent Protocol

```swift
protocol PerceptionEvent: Sendable {
    var id: UUID { get }
    var timestamp: Date { get }
    var sourceModule: ModuleID { get }
}
```

All events conform to this. Events are value types (`struct`).

### 3.3 EventHubActor

```swift
actor EventHubActor {
    func publish<E: PerceptionEvent>(_ event: E) async
    func subscribe<E: PerceptionEvent>(
        _ type: E.Type,
        handler: @Sendable (E) async -> Void
    ) async -> SubscriptionID
    func unsubscribe(_ id: SubscriptionID) async
}
```

**Backpressure:** EventHubActor uses a bounded per-subscriber queue (max 500 events). When a subscriber falls behind, oldest events are dropped and a warning is logged. At 16kHz/100ms audio chunks this allows ~50 seconds of buffering before drops — well beyond the Deepgram reconnect window.

### 3.4 ModuleSupervisorActor

```swift
actor ModuleSupervisorActor {
    func register(
        _ module: any BantiModule,
        restartPolicy: RestartPolicy,
        dependencies: Set<ModuleID> = []
    ) async
    func startAll() async throws
    func stopAll() async    // stops in reverse dependency order
    func restart(_ moduleID: ModuleID) async throws
}
```

`RestartPolicy`: `.never`, `.onFailure(maxRetries: Int, backoff: TimeInterval)`, `.always`.

The supervisor is responsible for publishing `ModuleStatusEvent` — it polls each module's `health()` every 5 seconds and publishes a `ModuleStatusEvent` when the status changes. Modules do not self-publish status events.

### 3.5 ConfigActor

```swift
actor ConfigActor {
    init(envFilePath: String)
    func value(for key: String) -> String?
    func require(_ key: String) throws -> String
}
```

Parses `.env` files with a built-in parser: strips `export ` prefix, ignores `#` comments and blank lines, splits on first `=`. No third-party dependency needed.

### 3.6 StateRegistryActor

```swift
actor StateRegistryActor {
    func update(_ moduleID: ModuleID, status: ModuleHealth) async
    func status(for moduleID: ModuleID) async -> ModuleHealth?
    func allStatuses() async -> [ModuleID: ModuleHealth]
    func lastError(for moduleID: ModuleID) async -> Error?
}
```

## 4. Event Contracts (V1)

All event type definitions live in `Core/Events/` so any module can reference them without cross-module imports.

| Event | Producer | Consumers | Payload |
|---|---|---|---|
| `AudioFrameEvent` | `MicrophoneCaptureActor` | `DeepgramStreamingActor` | `Data` (PCM Int16 16kHz mono), timestamp, sequence number |
| `RawTranscriptEvent` | `DeepgramStreamingActor` | `TranscriptProjectionActor` | text, speaker ID, confidence, is_final, audio start/end time |
| `TranscriptSegmentEvent` | `TranscriptProjectionActor` | `TranscriptViewModel` | speaker label, finalized text, time range |
| `ModuleStatusEvent` | `ModuleSupervisorActor` | `StateRegistryActor`, UI | module ID, old status, new status, timestamp |

Key rule: **modules never import each other**. They only know about event types (in `Core/Events/`) and `EventHubActor`.

## 5. Data Flow

### 5.1 Audio Thread Bridging

AVAudioEngine's `installTap(onBus:)` callback runs on a real-time audio rendering thread. Actor methods cannot be awaited from this thread without risking audio glitches.

**Strategy:** The tap callback writes PCM data into a lock-free ring buffer (`os_unfair_lock`-guarded or `Atomics`-based). A separate `Task` inside `MicrophoneCaptureActor` drains the buffer at a regular interval (~50ms) and publishes `AudioFrameEvent` to the EventHub. This decouples the real-time audio thread from Swift's cooperative concurrency.

### 5.2 Steady-State Flow

```
Mic hardware
  → AVAudioEngine tap (real-time thread, writes to lock-free ring buffer)
    → MicrophoneCaptureActor drain task (reads buffer, publishes AudioFrameEvent)
      → DeepgramStreamingActor (WebSocket to Deepgram streaming API)
        → receives JSON with speaker labels
        → publishes RawTranscriptEvent
          → TranscriptProjectionActor (merges partials, finalizes segments)
            → publishes TranscriptSegmentEvent
              → TranscriptViewModel (@MainActor, drives SwiftUI)
```

### 5.3 Startup Sequence

1. App launch initializes infrastructure: `ConfigActor` → `EventHubActor` → `StateRegistryActor`.
2. `ModuleSupervisorActor` is created with references to EventHub and StateRegistry.
3. Perception modules are registered with dependencies.
4. `supervisor.startAll()` starts modules in dependency order:
   - `MicrophoneCaptureActor` (no module dependencies)
   - `DeepgramStreamingActor` (no module dependencies)
   - `TranscriptProjectionActor` (no module dependencies)
5. Each module subscribes to its events during `start()`.
6. `TranscriptViewModel` subscribes to `TranscriptSegmentEvent` independently (not supervisor-managed).
7. Supervisor begins health polling (every 5s).

### 5.4 Shutdown Sequence

`supervisor.stopAll()` stops modules in **reverse dependency order**. After all modules stop, the EventHub and StateRegistry are torn down.

## 6. Error Handling

| Failure | Response |
|---|---|
| Mic permission denied | `.failed`, no retry, UI shows permission prompt |
| Mic hardware disconnected | `.degraded`, retry with backoff (max 3) |
| Deepgram WebSocket drops | Auto-reconnect with exponential backoff (1s, 2s, 4s), buffer audio during gap |
| Deepgram auth failure | `.failed`, no retry, surface to UI |
| Malformed Deepgram JSON | Log via `os_log` + skip, stay `.healthy` unless error rate >10% in 30s → `.degraded` |

### 6.1 Ring Buffer for Resilience

`MicrophoneCaptureActor` maintains a 10-second ring buffer of PCM frames (independent of the lock-free audio-thread buffer — this is a higher-level replay buffer).

**Replay deduplication strategy:** Each `AudioFrameEvent` carries a monotonic sequence number. When `DeepgramStreamingActor` reconnects, it records the sequence number of the last frame sent before the disconnect. On replay, only frames with sequence numbers *after* the last-sent are forwarded to the new WebSocket session. `TranscriptProjectionActor` additionally uses audio timestamp ranges to discard any `RawTranscriptEvent` that overlaps with already-finalized segments (timestamp-based dedup, not text-based).

### 6.2 Logging

All modules use `os_log` with a per-module subsystem (`com.banti.<module-id>`) and category. No third-party logging framework.

### 6.3 App Lifecycle

On macOS sleep: capture pauses (AVAudioEngine stops). On wake: supervisor restarts mic capture module. When the app window is hidden, capture continues (always-on listening).

## 7. TranscriptProjectionActor Merge Algorithm

1. **Partial handling:** Deepgram sends results with `is_final: false` (interim) and `is_final: true` (final). Interim results for the *current utterance* replace the previous interim in a staging buffer. Only `is_final: true` results are promoted to finalized segments.
2. **Segment finalization trigger:** A `TranscriptSegmentEvent` is published when Deepgram sends `is_final: true`. No timer-based finalization in v1.
3. **Speaker label stability:** Deepgram may reassign speaker IDs across utterances. The projection actor maintains a stable speaker mapping table: first-seen Deepgram speaker index → stable `Speaker N` label. If Deepgram resets speakers on reconnect, the mapping continues from the last assigned label.
4. **Segment length:** No maximum segment length enforced in v1 — segments correspond to Deepgram's natural utterance boundaries.

## 8. Deepgram Connection Parameters

WebSocket URL query parameters (configurable via `ConfigActor`):

| Parameter | Default |
|---|---|
| `model` | `nova-2` |
| `language` | `en` |
| `encoding` | `linear16` |
| `sample_rate` | `16000` |
| `channels` | `1` |
| `diarize` | `true` |
| `interim_results` | `true` |
| `punctuate` | `true` |

## 9. Project Structure (as implemented in repo)

```
Banti/
├── Banti.xcodeproj
├── Banti/
│   ├── BantiApp.swift                          # Wires EventHub, supervisor, mic, Deepgram, projection, Brain, Speech
│   ├── Info.plist                              # NSMicrophoneUsageDescription
│   ├── Banti.entitlements                      # com.apple.security.device.audio-input (+ dev entitlements as needed)
│   ├── Config/
│   │   ├── ConfigActor.swift                   # .env parser (supports quoted values) + runtime config
│   │   └── Environment.swift                   # Typed config keys (Deepgram, Cerebras, Cartesia)
│   ├── Core/
│   │   ├── BantiModule.swift                   # ModuleID, Capability, ModuleHealth, BantiModule protocol
│   │   ├── PerceptionEvent.swift               # Event protocol + SubscriptionID
│   │   ├── EventHubActor.swift                 # Pub/sub hub with backpressure
│   │   ├── ModuleSupervisorActor.swift         # Lifecycle + health polling + ModuleStatusEvent
│   │   ├── StateRegistryActor.swift
│   │   ├── AudioRingBuffer.swift
│   │   └── Events/
│   │       ├── AudioFrameEvent.swift
│   │       ├── RawTranscriptEvent.swift
│   │       ├── TranscriptSegmentEvent.swift
│   │       ├── ModuleStatusEvent.swift
│   │       ├── BrainThoughtEvent.swift
│   │       ├── BrainResponseEvent.swift
│   │       └── SpeechPlaybackEvent.swift
│   ├── Modules/
│   │   ├── Perception/Microphone/
│   │   │   ├── MicrophoneCaptureActor.swift    # AVAudioEngine; voice processing optional (default off)
│   │   │   ├── DeepgramStreamingActor.swift
│   │   │   └── TranscriptProjectionActor.swift
│   │   ├── Brain/BrainActor.swift              # Cerebras JSON decision loop → thoughts / spoken replies
│   │   └── Action/SpeechActor.swift            # Cartesia TTS playback
│   └── UI/
│       ├── TranscriptViewModel.swift
│       └── TranscriptView.swift
├── BantiTests/
│   ├── BrainActorTests.swift
│   ├── SpeechActorTests.swift
│   ├── TranscriptProjectionActorTests.swift    # includes MicrophoneCaptureActor prompt-contract tests
│   ├── EventHubActorTests.swift
│   ├── ConfigActorTests.swift
│   ├── DeepgramParsingTests.swift
│   ├── ModuleSupervisorActorTests.swift
│   ├── StateRegistryActorTests.swift
│   └── Helpers/ (MockPerceptionModule → BantiModule, TestRecorder)
└── .env                                         # API keys (gitignored)
```

## 10. Testing Strategy

- **Unit tests**: each actor tested in isolation with a mock `EventHubActor` — verify correct events published for given inputs.
- **Integration test**: wire real actors with a mock Deepgram WebSocket server (local), verify end-to-end transcript output.
- **Protocol conformance tests**: generic test suite any `BantiModule` can run against (start/stop/health lifecycle).
- **No UI tests in v1** — correctness validated at the `TranscriptSegmentEvent` level.

## 11. Dependencies

- **`URLSessionWebSocketTask`** (Foundation) for Deepgram WebSocket streaming — no Deepgram SDK needed
- **AVFoundation** (system framework) for mic capture
- **SwiftUI** (system framework) for UI
- **os** (system framework) for `os_log` logging
- **No third-party dependencies**

## 12. Out of Scope (original V1 mic spec)

- System audio capture (future `SystemAudioActor`)
- Persistent transcript storage (beyond optional `context.md` working memory for Brain)
- Communication channels
- Multi-device support

**Note:** The running app may also include **Brain** (Cerebras) and **Speech** (Cartesia) modules; those were out of scope for the original mic-only V1 write-up but are present in the codebase.

## 13. Known limitations (operational)

- **Open-speaker + hot mic:** TTS playback can be picked up by the microphone, transcribed, and fed back into the cognitive loop. Mitigations (headphones, echo cancellation, or gating while `SpeechPlaybackEvent` is active) are not fully implemented; treat as a known risk when using built-in speakers.
- **LLM output shape:** Brain decisions rely on JSON-shaped model output; malformed completions fall back to `wait` — prompt text is tuned but not formally schema-enforced.
