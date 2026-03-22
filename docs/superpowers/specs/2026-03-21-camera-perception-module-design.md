# Camera Perception Module Design

**Date:** 2026-03-21
**Status:** Approved

---

## Overview

Add a Camera perception module to Banti, mirroring the existing Microphone pipeline architecture. A single `CameraFrameActor` continuously captures frames and publishes them to EventHub. Analysis actors subscribe independently and self-throttle. The first analysis actor is `SceneDescriptionActor`, which sends frames to a configurable `VisionProvider` and publishes plain-text scene descriptions to Brain.

The design is explicitly extensible: adding future actors (emotion detection, face detection, body movement) requires no changes to the capture layer or `VisionProvider`.

---

## Pipeline

```
AVCaptureSession (camera hardware)
    │ tap on serial queue → JPEG compression → CameraLatestFrameBuffer
    ▼
CameraFrameActor          → publishes CameraFrameEvent every CAMERA_CAPTURE_INTERVAL_MS (default 200ms)
    │ (EventHub)
    ▼
SceneDescriptionActor     → self-throttles to SCENE_DESCRIPTION_INTERVAL_S (default 5s)
                          → calls VisionProvider.describe(jpeg:, prompt:)
                          → publishes SceneDescriptionEvent (text, captureTime, responseTime)
    │ (EventHub)
    ▼
EventLoggerActor + EventLogViewModel  (observers — no Brain actor yet)
```

> **Note:** BrainActor has been removed from the codebase. `SceneDescriptionEvent` is currently consumed only by `EventLoggerActor` (Console logging) and `EventLogViewModel` (UI feed). When a Brain module is added in a future phase it will subscribe to `SceneDescriptionEvent` here.

Existing mic pipeline for reference:
```
MicrophoneCaptureActor → AudioFrameEvent → DeepgramStreamingActor → RawTranscriptEvent
    → TranscriptProjectionActor → TranscriptSegmentEvent
```

---

## New Files

```
Banti/Banti/Modules/Perception/Camera/
    CameraFrameActor.swift           — AVCaptureSession capture, publishes CameraFrameEvent
    SceneDescriptionActor.swift      — throttle + VisionProvider call, publishes SceneDescriptionEvent
    VisionProvider.swift             — protocol definition

Banti/Banti/Modules/Perception/Camera/Providers/
    ClaudeVisionProvider.swift       — Anthropic messages API with image content block

Banti/Banti/Core/
    CameraLatestFrameBuffer.swift    — thread-safe single-slot frame buffer (see below)

Banti/Banti/Core/Events/
    CameraFrameEvent.swift           — PerceptionEvent: jpeg Data, sequenceNumber, frameWidth, frameHeight
    SceneDescriptionEvent.swift      — PerceptionEvent: text, captureTime, responseTime
```

---

## VisionProvider Protocol

```swift
protocol VisionProvider: Sendable {
    func describe(jpeg: Data, prompt: String) async throws -> String
}
```

Mirrors `LLMProvider` exactly. `SceneDescriptionActor` has a private `buildProvider() async throws -> any VisionProvider` method (same pattern as `BrainActor.buildProvider()`), reading `VISION_PROVIDER` from config. Initially only `"claude"` is supported. Adding a new provider means a new conformance + one case in the switch — no actor changes.

`ClaudeVisionProvider` sends a single Anthropic messages API request with:
- JPEG as a base64 `image` content block (`"type": "image"`, `"source": {"type": "base64", "media_type": "image/jpeg", "data": "..."}`)
- Prompt as a `text` content block
- Uses `ANTHROPIC_API_KEY` (shared with Brain) and `ANTHROPIC_VISION_MODEL` (default `claude-haiku-4-5` — same family as the default LLM provider, balances cost and latency)
- `max_tokens: 256` (scene descriptions are short)

---

## CameraLatestFrameBuffer

A thread-safe single-slot buffer. Unlike `AudioRingBuffer` (which accumulates all frames), the camera buffer keeps only the most recent frame — there is no value in processing stale frames when only ambient awareness is needed.

```swift
// CameraLatestFrameBuffer.swift
final class CameraLatestFrameBuffer: @unchecked Sendable {
    private var latest: Data?
    private let lock = NSLock()

    func store(_ jpeg: Data) {
        lock.withLock { latest = jpeg }
    }

    func take() -> Data? {
        lock.withLock {
            defer { latest = nil }
            return latest
        }
    }
}
```

The `drainTask` calls `take()` — if no new frame arrived since the last drain, it returns `nil` and skips publishing.

---

## CameraFrameActor

**Capabilities:** `.videoCapture`

**Capture loop:**
- `AVCaptureSession` with `AVCaptureVideoDataOutput` on a dedicated serial `DispatchQueue` (non-actor thread, same bridge pattern as `AudioRingBuffer`)
- Each frame downscaled to max 1280px on the long edge before JPEG compression (prevents oversized payloads; at quality 0.7 this produces ~80–150 KB per frame, safe for EventHub queue)
- Compressed JPEG pushed into `CameraLatestFrameBuffer`
- A `drainTask` wakes every `CAMERA_CAPTURE_INTERVAL_MS` (default 200ms), calls `buffer.take()`, and if non-nil assigns a monotonic `sequenceNumber` and publishes `CameraFrameEvent`

**Replay buffer:**
Conforms to `CameraFrameReplayProvider` for forward-compatibility with future analysis actors that may need recent frame history (e.g. a motion detection actor that restarts mid-session):

```swift
protocol CameraFrameReplayProvider: Actor {
    func replayFrames(after lastSeq: UInt64) async -> [(seq: UInt64, data: Data)]
}
```

Note: the tuple label is `data:` (matching `AudioFrameReplayProvider`) rather than `jpeg:` for consistency across replay protocols. Callers should not rely on the label to convey encoding — the `CameraFrameEvent` type carries that semantic.

- Rolling buffer of last **30 published frames** (≈6s at 200ms)
- Analysis actors accept `(any CameraFrameReplayProvider)?` in init
- `SceneDescriptionActor` accepts the replay provider but does not use it on reconnect — VLM calls are stateless HTTP, there is no stream to resume. An actor that does need replay (future use) must explicitly cap replayed frames to avoid triggering N VLM calls on restart.

**Platform requirements:**
- `NSCameraUsageDescription` in `Info.plist`: `"Banti uses the camera to understand the visual scene and provide context-aware assistance."`
- Camera entitlement in `.entitlements`

---

## SceneDescriptionActor

**Capabilities:** `.sceneDescription`

**Behavior:**
- On `start()`: calls `buildProvider()` to instantiate the `VisionProvider`, then subscribes to `CameraFrameEvent`. The provider is captured by value in the EventHub subscription closure (not stored as an actor property), matching `BrainActor`'s pattern exactly:
  ```swift
  let provider = try await buildProvider()
  subscriptionID = await eventHub.subscribe(CameraFrameEvent.self) { [weak self] event in
      guard let self else { return }
      await self.handleFrame(event, provider: provider)
  }
  ```
- Self-throttles: skips frames until `SCENE_DESCRIPTION_INTERVAL_S` (default 5s) has elapsed since `lastDescribedAt: Date?`. On a chosen frame, calls `VisionProvider.describe(jpeg:, prompt:)` async.
- `captureTime` in the published event = `event.timestamp` (the moment the frame was captured by `CameraFrameActor`). `responseTime` = `Date()` after the VLM call returns.
- Prompt sourced from `SCENE_DESCRIPTION_PROMPT` (default: `"Describe the visual scene concisely, focusing on people, objects, and activities."`)
- Publishes `SceneDescriptionEvent` to EventHub
- On VLM failure: logs error, marks health `.degraded`, skips frame, waits for next interval (no retry — stateless HTTP, next interval will retry naturally)
- Accepts `(any CameraFrameReplayProvider)?` in init for forward-compatibility

---

## Events

### CameraFrameEvent
```swift
struct CameraFrameEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID   // "camera-capture"
    let jpeg: Data
    let sequenceNumber: UInt64
    let frameWidth: Int
    let frameHeight: Int
}
```

### SceneDescriptionEvent
```swift
struct SceneDescriptionEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID   // "scene-description"
    let text: String
    let captureTime: Date        // event.timestamp from the source CameraFrameEvent
    let responseTime: Date       // Date() after VLM call completes
}
```

---

## BantiModule Extensions

### New Capabilities (BantiModule.swift)
```swift
static let videoCapture     = Capability("video-capture")
static let sceneDescription = Capability("scene-description")
```

### New EnvKeys (Environment.swift)
```swift
static let cameraCaptureIntervalMs   = "CAMERA_CAPTURE_INTERVAL_MS"   // default 200
static let visionProvider            = "VISION_PROVIDER"               // "claude"
static let sceneDescriptionIntervalS = "SCENE_DESCRIPTION_INTERVAL_S"  // default 5
static let sceneDescriptionPrompt    = "SCENE_DESCRIPTION_PROMPT"
static let anthropicVisionModel      = "ANTHROPIC_VISION_MODEL"        // default "claude-haiku-4-5"
```

---

## App Wiring (BantiApp.swift)

Registration order follows the topological constraint — analysis actors must subscribe before capture starts publishing. `sceneDesc` depends on `camera` being started after it:

```swift
let camera = CameraFrameActor(eventHub: hub, config: cfg)
let sceneDesc = SceneDescriptionActor(eventHub: hub, config: cfg, replayProvider: camera)

// sceneDesc must subscribe to CameraFrameEvent before camera starts publishing.
await sup.register(sceneDesc, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
await sup.register(camera,    restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [sceneDesc.id])
```

When a future Brain module is added, it should be registered before `sceneDesc` and listed as a dependency so the topology is preserved.

---

## Extensibility

Adding a future `EmotionDetectionActor`:
1. Create `EmotionDetectionActor.swift` under `Modules/Perception/Camera/`
2. Subscribe to `CameraFrameEvent`, self-throttle as needed
3. Add `static let emotionDetection = Capability("emotion-detection")` to `BantiModule.swift`
4. Define `EmotionEvent` under `Core/Events/`
5. Register in `BantiApp.swift` before `camera`

Zero changes to `CameraFrameActor`, `VisionProvider`, or any existing analysis actor. The only edits to existing files are adding the capability constant and the wiring in `BantiApp.swift`.

The same pattern applies to the microphone pipeline — future actors subscribe to `AudioFrameEvent` and self-throttle independently.
