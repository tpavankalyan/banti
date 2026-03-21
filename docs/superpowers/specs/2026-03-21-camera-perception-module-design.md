# Camera Perception Module Design

**Date:** 2026-03-21
**Status:** Approved

---

## Overview

Add a Camera perception module to Banti, mirroring the existing Microphone pipeline architecture. A single `CameraFrameActor` continuously captures frames and publishes them to EventHub. Analysis actors subscribe independently and self-throttle. The first analysis actor is `SceneDescriptionActor`, which sends frames to a configurable `VisionProvider` and publishes plain-text scene descriptions to Brain.

The design is explicitly extensible: adding future actors (emotion detection, face detection, body movement) requires no changes to the capture layer.

---

## Pipeline

```
AVCaptureSession (camera hardware)
    │ tap on serial queue → JPEG compression → CameraFrameBuffer
    ▼
CameraFrameActor          → publishes CameraFrameEvent every CAMERA_CAPTURE_INTERVAL_MS (default 200ms)
    │ (EventHub)
    ▼
SceneDescriptionActor     → self-throttles to SCENE_DESCRIPTION_INTERVAL_S (default 5s)
                          → calls VisionProvider.describe(jpeg:, prompt:)
                          → publishes SceneDescriptionEvent (text, captureStartTime, captureEndTime)
    │ (EventHub)
    ▼
BrainActor                → subscribes to SceneDescriptionEvent alongside TranscriptSegmentEvent
                          → appends to context.md: [HH:mm:ss] (scene) "..."
```

---

## New Files

```
Banti/Banti/Modules/Perception/Camera/
    CameraFrameActor.swift           — AVCaptureSession capture, publishes CameraFrameEvent
    SceneDescriptionActor.swift      — throttle + VisionProvider call, publishes SceneDescriptionEvent
    VisionProvider.swift             — protocol + factory

Banti/Banti/Modules/Perception/Camera/Providers/
    ClaudeVisionProvider.swift       — Anthropic messages API with image content block

Banti/Banti/Core/Events/
    CameraFrameEvent.swift           — PerceptionEvent: jpeg Data, sequenceNumber, frameSize
    SceneDescriptionEvent.swift      — PerceptionEvent: text, captureStartTime, captureEndTime
```

---

## VisionProvider Protocol

```swift
protocol VisionProvider: Sendable {
    func describe(jpeg: Data, prompt: String) async throws -> String
}
```

Mirrors `LLMProvider` exactly. A `VisionProviderFactory` reads `VISION_PROVIDER` from config (initially only `"claude"` supported). Adding a new provider (GPT-4V, on-device CoreML) means a new conformance + one case in the factory — no actor changes.

`ClaudeVisionProvider` sends a single Anthropic messages API request with:
- JPEG as a base64 `image` content block
- Prompt as a `text` content block
- Uses `ANTHROPIC_API_KEY` (shared with Brain) and `ANTHROPIC_VISION_MODEL` (default `claude-opus-4-6`)

---

## CameraFrameActor

**Capabilities:** `.videoCapture`

**Capture loop:**
- `AVCaptureSession` with `AVCaptureVideoDataOutput` on a dedicated serial `DispatchQueue` (non-actor thread, same bridge pattern as `AudioRingBuffer`)
- Each frame compressed to JPEG at quality 0.7 and pushed into a thread-safe `CameraFrameBuffer`
- A `drainTask` wakes every `CAMERA_CAPTURE_INTERVAL_MS` (default 200ms), pulls the **latest** frame from the buffer (not all — only the most recent matters), assigns a monotonic `sequenceNumber`, publishes `CameraFrameEvent`

**Replay buffer:**
- Conforms to `CameraFrameReplayProvider` protocol (parallel to `AudioFrameReplayProvider`):
  ```swift
  protocol CameraFrameReplayProvider: Actor {
      func replayFrames(after lastSeq: UInt64) async -> [(seq: UInt64, jpeg: Data)]
  }
  ```
- Rolling buffer of last **30 frames** (≈6s at 200ms) — smaller than mic's 100 due to larger frame sizes
- Analysis actors accept `(any CameraFrameReplayProvider)?` in init for future restart recovery

**Platform requirements:**
- `NSCameraUsageDescription` in `Info.plist`
- Camera entitlement in `.entitlements`

---

## SceneDescriptionActor

**Capabilities:** `.sceneDescription`

**Behavior:**
- Subscribes to `CameraFrameEvent` from EventHub
- Self-throttles: skips frames until `SCENE_DESCRIPTION_INTERVAL_S` (default 5s) has elapsed since last successful VLM call, tracked via `lastDescribedAt: Date?`
- On a chosen frame: calls `VisionProvider.describe(jpeg:, prompt:)` with prompt from `SCENE_DESCRIPTION_PROMPT` (default: `"Describe the visual scene concisely, focusing on people, objects, and activities."`)
- Publishes `SceneDescriptionEvent` to EventHub
- On VLM failure: marks health `.degraded`, skips frame, waits for next interval (no retry — stateless HTTP)
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
    let captureStartTime: Date
    let captureEndTime: Date
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
static let cameraCapturIntervalMs    = "CAMERA_CAPTURE_INTERVAL_MS"   // default 200
static let visionProvider            = "VISION_PROVIDER"               // "claude"
static let sceneDescriptionIntervalS = "SCENE_DESCRIPTION_INTERVAL_S"  // default 5
static let sceneDescriptionPrompt    = "SCENE_DESCRIPTION_PROMPT"
static let anthropicVisionModel      = "ANTHROPIC_VISION_MODEL"        // default "claude-opus-4-6"
```

---

## BrainActor Integration

`BrainActor` subscribes to `SceneDescriptionEvent` alongside `TranscriptSegmentEvent`. Scene descriptions are appended to `context.md`:

```
[14:32:01] (scene) "A person sitting at a desk, looking at two monitors. Coffee cup visible."
```

This gives the LLM ambient visual context interleaved with conversation history.

---

## App Wiring (BantiApp.swift)

Registration order follows the same topological constraint as the mic pipeline — analysis actors must subscribe before capture starts:

```swift
let camera = CameraFrameActor(eventHub: hub, config: cfg)
let sceneDesc = SceneDescriptionActor(eventHub: hub, config: cfg, replayProvider: camera)

await sup.register(sceneDesc, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
await sup.register(camera, restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [sceneDesc.id])
```

---

## Extensibility

Adding a future `EmotionDetectionActor`:
1. Create `EmotionDetectionActor.swift` under `Modules/Perception/Camera/`
2. Subscribe to `CameraFrameEvent`, self-throttle as needed
3. Define `EmotionEvent` under `Core/Events/`
4. Register in `BantiApp.swift` before `camera`
5. Zero changes to `CameraFrameActor`, `VisionProvider`, or any existing actor

The same pattern applies to the microphone pipeline — future actors (e.g. speaker emotion from audio) follow the same: subscribe to `AudioFrameEvent`, self-throttle, publish new event type.
