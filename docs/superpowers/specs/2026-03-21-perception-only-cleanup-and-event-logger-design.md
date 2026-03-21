# Perception-Only Cleanup + EventLoggerActor Design

**Date:** 2026-03-21
**Status:** Approved

## Goal

Strip the codebase down to perception modules only (Camera + Microphone pipelines), remove Brain and Action modules, and add a passive `EventLoggerActor` that logs every event on the bus to Console.app so the input pipeline can be observed and debugged in real time.

---

## Part 1 — Remove Non-Perception Code

### Files to delete

**Modules:**
- `Banti/Modules/Brain/BrainActor.swift`
- `Banti/Modules/Brain/LLMProvider.swift`
- `Banti/Modules/Brain/CerebrasProvider.swift`
- `Banti/Modules/Brain/ClaudeProvider.swift`
- `Banti/Modules/Action/SpeechActor.swift`

**Events (only consumed by Brain/Speech):**
- `Banti/Core/Events/BrainResponseEvent.swift`
- `Banti/Core/Events/BrainThoughtEvent.swift`
- `Banti/Core/Events/SpeechPlaybackEvent.swift`

**Tests:**
- `BantiTests/BrainActorTests.swift`
- `BantiTests/SpeechActorTests.swift`

### BantiApp.swift changes

- Remove `brain: BrainActor` and `speech: SpeechActor` stored properties
- Remove their init lines and bootstrap registrations
- Remove the `dependencies: [brain.id]` constraint on `sceneDesc` registration — that constraint only existed so `BrainActor` would subscribe to `SceneDescriptionEvent` before the camera started publishing; it is no longer needed
- Remove `brain` and `speech` parameters from the `bootstrap()` signature

### What stays

All perception modules and their events are untouched:

| Event | Source |
|---|---|
| `AudioFrameEvent` | `MicrophoneCaptureActor` |
| `RawTranscriptEvent` | `DeepgramStreamingActor` |
| `TranscriptSegmentEvent` | `TranscriptProjectionActor` |
| `CameraFrameEvent` | `CameraFrameActor` |
| `SceneDescriptionEvent` | `SceneDescriptionActor` |
| `ModuleStatusEvent` | `ModuleSupervisorActor` |

`TranscriptViewModel` and `TranscriptView` are kept — the view subscribes to `TranscriptSegmentEvent` and is a useful live readout of the mic pipeline.

---

## Part 2 — EventLoggerActor

### Location

`Banti/Core/EventLoggerActor.swift`

### Interface

```swift
actor EventLoggerActor: BantiModule {
    nonisolated let id = ModuleID("event-logger")
    nonisolated let capabilities: Set<Capability> = []
    // start() / stop() / health()
}
```

### Behaviour

On `start()`, subscribes to all 6 event types. On `stop()`, unsubscribes all.

All logging uses `os.Logger(subsystem: "com.banti.core", category: "EventLog")` — filterable in Console.app with `category == "EventLog"`.

| Event | Log fields | Throttle |
|---|---|---|
| `AudioFrameEvent` | seq#, byte count, sampleRate | Every 100th frame (fires ~10×/sec) |
| `CameraFrameEvent` | seq#, byte count, WxH | None |
| `RawTranscriptEvent` | speaker, confidence, isFinal, text | None |
| `TranscriptSegmentEvent` | speaker, isFinal, text | None |
| `SceneDescriptionEvent` | VLM latency (responseTime − captureTime), text prefix (60 chars) | None |
| `ModuleStatusEvent` | moduleID, old→new status | None |

`AudioFrameEvent` throttling uses a simple counter (`audioFrameCount % 100 == 0`) to avoid flooding Console at audio buffer rate.

### Registration

Registered **first** in the bootstrap before any other module, so it is subscribed before any module can publish:

```swift
await sup.register(eventLogger, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
// ... then mic, deepgram, projection, camera, sceneDesc
```

---

## Testing

No new test file needed. `EventLoggerActor` is a pure observer with no outputs other than log lines. Correct registration order (logger first) is verified by the existing `ModuleSupervisorActorTests`.

---

## Files Changed Summary

| Action | File |
|---|---|
| Create | `Banti/Core/EventLoggerActor.swift` |
| Modify | `Banti/BantiApp.swift` |
| Delete | `Banti/Modules/Brain/BrainActor.swift` |
| Delete | `Banti/Modules/Brain/LLMProvider.swift` |
| Delete | `Banti/Modules/Brain/CerebrasProvider.swift` |
| Delete | `Banti/Modules/Brain/ClaudeProvider.swift` |
| Delete | `Banti/Modules/Action/SpeechActor.swift` |
| Delete | `Banti/Core/Events/BrainResponseEvent.swift` |
| Delete | `Banti/Core/Events/BrainThoughtEvent.swift` |
| Delete | `Banti/Core/Events/SpeechPlaybackEvent.swift` |
| Delete | `BantiTests/BrainActorTests.swift` |
| Delete | `BantiTests/SpeechActorTests.swift` |
