# Banti Architecture

## Mental model

Banti models the human perceptual system. Sensory organs collect raw input; dedicated processing modules transform it into structured percepts; a shared "working memory" (event bus) makes those percepts available to any subscriber.

The current phase covers **perception only**: collecting and publishing. No cognitive loop or action output exists yet.

---

## Layers

### 1. Infrastructure

| Component | File | Role |
|---|---|---|
| `EventHubActor` | `Core/EventHubActor.swift` | Typed, actor-isolated publish/subscribe bus |
| `BoundedEventQueue` | (same file) | Per-subscriber `AsyncStream` with `bufferingNewest(N)` drop policy |
| `ModuleSupervisorActor` | `Core/ModuleSupervisorActor.swift` | Topological startup, rollback on failure, 5-second health polling |
| `StateRegistryActor` | `Core/StateRegistryActor.swift` | Mutable per-module `ModuleHealth` store |
| `ConfigActor` | `Config/ConfigActor.swift` | `.env` + process env reader; thread-safe via actor isolation |

### 2. Module contract

Every module conforms to `BantiModule`:

```swift
protocol BantiModule: Actor {
    nonisolated var id: ModuleID { get }
    nonisolated var capabilities: Set<Capability> { get }
    func start() async throws
    func stop() async
    func health() async -> ModuleHealth
}
```

`ModuleHealth` has three states: `.healthy`, `.degraded(reason:)`, `.failed(error:)`. The supervisor polls health every 5 seconds and publishes a `ModuleStatusEvent` on any transition.

**Note:** `RestartPolicy` (`.never`, `.onFailure`, `.always`) is stored per-module but the supervisor does not yet automatically enforce it. Restarts are currently triggered manually (e.g. mic on system wake). Automatic restart enforcement is planned.

### 3. Event bus

`EventHubActor` uses Swift `actor` isolation. All `publish` and `subscribe` calls hop onto the hub's executor. Each subscriber gets its own `BoundedEventQueue` (an `AsyncStream` with `.bufferingNewest(500)`) backed by a `Task` that drains events and calls the handler.

- **Type dispatch**: subscriptions are keyed by `ObjectIdentifier(E.self)`. Publishing `CameraFrameEvent` only wakes subscribers for that concrete type — no dynamic casting per subscriber.
- **Drop policy**: when a subscriber falls behind, the oldest queued events are dropped silently. High-frequency events (audio, camera, screen frames) are designed with this in mind.
- **Cleanup**: `unsubscribe(_:)` finishes the stream, which terminates the drain `Task` naturally.

### 4. Perception modules

#### Camera pipeline

```
AVCaptureSession → CaptureDelegate (off-actor) → CameraLatestFrameBuffer
                                                        │
                                               drainTask (every 200ms)
                                                        │
                                               CameraFrameEvent → EventHub
                                                        │
                                               SceneDescriptionActor
                                               (throttle 5s, VLM call)
                                                        │
                                               SceneDescriptionEvent → EventHub
```

- `CameraLatestFrameBuffer`: single-slot, newest-wins. If capture is faster than the drain interval, intermediate frames are discarded — only the most recent frame matters for ambient scene awareness.
- `SceneDescriptionActor` self-throttles by comparing `Date()` to `lastDescribedAt`. On VLM failure it marks itself `.degraded` and resumes automatically on the next interval.

#### Screen pipeline

```
SCStream → ScreenStreamOutput (off-actor) → ScreenLatestFrameBuffer
                                                   │
                                          drainTask (every 1000ms)
                                                   │
                                          ScreenFrameEvent → EventHub
                                                   │
                                          ScreenDescriptionActor
                                          (throttle 10s, VLM call)
                                                   │
                                          ScreenDescriptionEvent → EventHub

NSWorkspace.didActivateApplicationNotification
    │
ActiveAppActor
    │
ActiveAppEvent → EventHub
```

- `ScreenCaptureActor` uses ScreenCaptureKit (`SCStream`). Requires Screen Recording permission.
- `ActiveAppActor` is purely event-driven (no polling). Publishes an initial snapshot on `start()` so subscribers have context immediately.

#### Microphone pipeline

```
AVAudioEngine (tap) → AudioRingBuffer (accumulates 50ms chunks)
                              │
                     drainTask (every 50ms)
                              │
                     AudioFrameEvent → EventHub
                              │
                     DeepgramStreamingActor (WebSocket)
                              │
                     RawTranscriptEvent → EventHub (interim + final)
                              │
                     TranscriptProjectionActor
                     (deduplication, speaker labelling)
                              │
                     TranscriptSegmentEvent → EventHub
```

- `AudioRingBuffer`: accumulating (not single-slot) because audio frames must not be dropped before Deepgram receives them.
- `DeepgramStreamingActor` reconnects with exponential backoff (1 → 2 → 4 → 8 → 16s, max 5 attempts) and replays buffered frames via `AudioFrameReplayProvider`.

#### Accessibility pipeline

```
AXObserver (main run loop, C callback)
    │
AXEventBridge (bridges C callback → async Task)
    │
AXFocusActor.handleNotification(pid:notification:)
    │ (debounce 50ms for valueChanged)
    ▼
publishCurrentFocus → AXFocusEvent → EventHub
```

- `AXFocusActor` observes `kAXFocusedUIElementChangedNotification`, `kAXSelectedTextChangedNotification`, and `kAXValueChangedNotification` for the frontmost application.
- It re-registers the `AXObserver` on every app switch (via both `ActiveAppEvent` subscription and an `NSWorkspace` fallback).
- Value-changed events are debounced to avoid flooding on rapid keystrokes.
- Health degrades if the windowed error rate (AX attribute reads that fail) exceeds 20% in any 10-second window.

### 5. Observers

#### EventLoggerActor

A passive `BantiModule` that subscribes to all 10 event types and logs them to Console.app using `os.Logger`. Filter in Console with `category == "EventLog"` or `subsystem == "com.banti.core"`.

- Audio frames are throttled: every 100th frame is logged.
- All other events are logged at `.notice` or `.debug` level with no throttle.

#### EventLogViewModel + EventLogView

`@MainActor` SwiftUI observable. Subscribes to all 10 event types and appends formatted rows to a rolling 500-entry buffer. High-frequency events are throttled for readability:
- Audio: every 100th frame
- Raw camera frames: at most once per 60s
- Raw screen frames: at most once per 60s

---

## Threading model

All actors use Swift's cooperative thread pool by default. Cross-actor calls are `await`-based. The only non-actor concurrency is in the bridge objects:

| Bridge | Why non-isolated | Safety mechanism |
|---|---|---|
| `CaptureDelegate` (camera) | `AVCaptureVideoDataOutput` delegate callback on a `DispatchQueue` | Writes to `CameraLatestFrameBuffer` (NSLock) |
| `ScreenStreamOutput` (screen) | `SCStream` sample handler on a `DispatchQueue` | Writes to `ScreenLatestFrameBuffer` (NSLock) |
| `AudioRingBuffer` tap closure | `AVAudioEngine` tap runs on an audio thread | `NSLock` in `AudioRingBuffer` |
| `AXEventBridge` | AXObserver C callback on main run loop | Schedules `Task { await actor.handleNotification(...) }` |
| `ActiveAppActor.observer` | `NSWorkspace.NotificationCenter` notification | Schedules `Task { await actorRef?.handleActivation(...) }` |

---

## Startup sequence

`BantiApp.init()` constructs all actors, then fires a `Task` to call `bootstrap()`. Inside bootstrap:

1. Register all modules with the supervisor (in dependency order)
2. Call `vm.startListening()` — subscribes UI before any module publishes
3. Call `sup.startAll()` — starts modules in topological order

If any module fails to start, the supervisor rolls back (stops) all already-started modules in reverse order and surfaces the error to the UI via `vm.setError(_:)`.

Current startup order (post-topology sort):

```
event-logger → transcript-projection → deepgram-asr → mic-capture
scene-description → camera-capture
active-app
screen-description → screen-capture
ax-focus
```

---

## Known issues / planned work

1. **RestartPolicy not enforced**: Registered but the health-polling loop only emits status events. Auto-restart logic is a planned addition to `ModuleSupervisorActor`.

2. **Deepgram auth detection**: `DeepgramStreamingActor.handleReceiveError` checks `nsError.code == 401` to detect authentication failures, but URLSession WebSocket errors don't map HTTP status codes to NSError codes this way. The existing Deepgram JSON error detection (checking `err_msg` / `type == "Error"` in `handleMessage`) is the reliable path.

3. **Code duplication — buffers**: `CameraLatestFrameBuffer` and `ScreenLatestFrameBuffer` are identical. They could be merged into one class.

4. **Code duplication — buildProvider()**: `SceneDescriptionActor` and `ScreenDescriptionActor` both have identical `buildProvider()` methods. A shared factory function would eliminate the duplication.

5. **SCREEN_CAPTURE_DISPLAY_INDEX not implemented**: The env key is in the spec but `ScreenCaptureActor` always captures the first display returned by `SCShareableContent`.

6. **BrainActor / SpeechActor**: Removed in the perception-only cleanup phase. Will be re-added once the perception foundation is stable.
