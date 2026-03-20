# Microphone ASR + Speaker Diarization — Design Spec

**Date:** 2026-03-20
**Status:** Draft
**Module:** Perception — Microphone + Deepgram ASR

## 1. Goal

Build the first perception module for Banti: a macOS app that continuously captures microphone audio, streams it to Deepgram for real-time ASR with speaker diarization, and displays a live transcript with speaker labels in a SwiftUI interface.

The architecture must support adding many future perception modules (system audio, brain, communication channels) without modifying existing code.

## 2. Architecture

### 2.1 Core Model

Every module is a Swift `actor` conforming to a shared `PerceptionModule` protocol. Modules never import each other — they communicate exclusively through typed events on an `EventHubActor`.

### 2.2 Runtime Actors

| Actor | Responsibility |
|---|---|
| `EventHubActor` | Typed pub/sub for all cross-module messages |
| `ModuleSupervisorActor` | Lifecycle management, dependency ordering, restart policies |
| `ConfigActor` | Runtime configuration access (`.env` loading, hot-reload hooks) |
| `StateRegistryActor` | Module status snapshots, metrics, last-error tracking |

### 2.3 V1 Module Set

| Actor | Role |
|---|---|
| `MicrophoneCaptureActor` | Captures PCM audio frames from hardware mic via AVAudioEngine |
| `DeepgramStreamingActor` | Streams audio over WebSocket to Deepgram, receives transcript JSON |
| `TranscriptProjectionActor` | Merges partial results, produces finalized transcript segments |
| `TranscriptViewModel` | `@MainActor` bridge to SwiftUI for live transcript display |

### 2.4 Extensibility Path

New modules only need:
1. `PerceptionModule` protocol conformance
2. Event contract declarations (new event types)
3. Registration with `ModuleSupervisorActor`

Existing modules remain untouched unless event schemas change.

## 3. Component Interfaces

### 3.1 PerceptionModule Protocol

```swift
protocol PerceptionModule: Actor {
    var id: ModuleID { get }
    var capabilities: Set<Capability> { get }
    func start() async throws
    func stop() async
    func health() async -> ModuleHealth
}
```

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

### 3.4 ModuleSupervisorActor

```swift
actor ModuleSupervisorActor {
    func register(_ module: any PerceptionModule, restartPolicy: RestartPolicy) async
    func startAll() async throws
    func stopAll() async
    func restart(_ moduleID: ModuleID) async throws
}
```

`RestartPolicy`: `.never`, `.onFailure(maxRetries: Int, backoff: TimeInterval)`, `.always`.

## 4. Event Contracts (V1)

| Event | Producer | Consumers | Payload |
|---|---|---|---|
| `AudioFrameEvent` | `MicrophoneCaptureActor` | `DeepgramStreamingActor` | `Data` (PCM Int16 16kHz), timestamp, sequence number |
| `RawTranscriptEvent` | `DeepgramStreamingActor` | `TranscriptProjectionActor` | text, speaker ID, confidence, is_final, start/end time |
| `TranscriptSegment` | `TranscriptProjectionActor` | `TranscriptViewModel` | speaker label, finalized text, time range |
| `ModuleStatusEvent` | Any module | `StateRegistryActor`, UI | module ID, old/new status, timestamp |

Key rule: **modules never import each other**. They only know about event types and `EventHubActor`.

## 5. Data Flow

```
Mic hardware
  → MicrophoneCaptureActor (AVAudioEngine tap, 16kHz PCM chunks ~100ms)
    → publishes AudioFrameEvent
      → DeepgramStreamingActor (WebSocket to Deepgram streaming API)
        → receives JSON with speaker labels
        → publishes RawTranscriptEvent
          → TranscriptProjectionActor (merges partials, finalizes segments)
            → publishes TranscriptSegment
              → TranscriptViewModel (@MainActor, drives SwiftUI)
```

### 5.1 Startup Sequence (Supervised)

1. `ModuleSupervisorActor.startAll()` in dependency order:
   - `EventHubActor` (always first)
   - `MicrophoneCaptureActor` (depends on: EventHub)
   - `DeepgramStreamingActor` (depends on: EventHub)
   - `TranscriptProjectionActor` (depends on: EventHub)
2. Each module subscribes to its events during `start()`.
3. Supervisor monitors health via periodic `health()` polls (every 5s).

## 6. Error Handling

| Failure | Response |
|---|---|
| Mic permission denied | `.failed`, no retry, UI shows permission prompt |
| Mic hardware disconnected | `.degraded`, retry with backoff (max 3) |
| Deepgram WebSocket drops | Auto-reconnect with exponential backoff (1s, 2s, 4s), buffer audio during gap |
| Deepgram auth failure | `.failed`, no retry, surface to UI |
| Malformed Deepgram JSON | Log + skip, stay `.healthy` unless error rate >10% in 30s → `.degraded` |

### 6.1 Ring Buffer for Resilience

`MicrophoneCaptureActor` maintains a 10-second ring buffer of PCM frames. If Deepgram reconnects within that window, buffered frames are replayed to minimize transcript gaps.

## 7. Project Structure

```
Banti/
├── BantiApp.swift                          # App entry point
├── Info.plist                              # Microphone usage description
├── Config/
│   ├── ConfigActor.swift                   # .env loading, runtime config
│   └── Environment.swift                   # Typed config keys
├── Core/
│   ├── PerceptionModule.swift              # Protocol + ModuleID, Capability types
│   ├── PerceptionEvent.swift               # Event protocol + base types
│   ├── EventHubActor.swift                 # Pub/sub hub
│   ├── ModuleSupervisorActor.swift         # Lifecycle + restart policies
│   └── StateRegistryActor.swift            # Status tracking
├── Modules/
│   └── Microphone/
│       ├── MicrophoneCaptureActor.swift     # AVAudioEngine tap + ring buffer
│       ├── AudioFrameEvent.swift           # Event type
│       ├── DeepgramStreamingActor.swift    # WebSocket client
│       ├── RawTranscriptEvent.swift        # Event type
│       ├── TranscriptProjectionActor.swift # Partial merge logic
│       └── TranscriptSegment.swift         # Finalized segment event
├── UI/
│   ├── TranscriptViewModel.swift           # @MainActor view model
│   └── TranscriptView.swift                # SwiftUI transcript display
└── Resources/
    └── .env                                # Deepgram API key (gitignored)
```

## 8. Testing Strategy

- **Unit tests**: each actor tested in isolation with a mock `EventHubActor` — verify correct events published for given inputs.
- **Integration test**: wire real actors with a mock Deepgram WebSocket server (local), verify end-to-end transcript output.
- **Protocol conformance tests**: generic test suite any `PerceptionModule` can run against (start/stop/health lifecycle).
- **No UI tests in v1** — correctness validated at the `TranscriptSegment` level.

## 9. Dependencies

- **Deepgram Swift SDK** or raw `URLSessionWebSocketTask` for WebSocket streaming
- **AVFoundation** (system framework) for mic capture
- **SwiftUI** (system framework) for UI
- No third-party dependencies beyond Deepgram connectivity

## 10. Out of Scope (V1)

- System audio capture (future `SystemAudioActor`)
- Persistent transcript storage
- Brain / reasoning modules
- Communication channels
- Multi-device support
- Audio playback
