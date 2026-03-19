# Banti Perception Pipeline Design

**Date:** 2026-03-18
**Status:** Approved
**Scope:** Perception layer only — how observations are gathered and structured. Output/assistant layer is out of scope.
**Minimum OS:** macOS 14 (matches existing Package.swift; covers all required Vision APIs)

---

## Goal

Replace the single Moondream model with a multi-modal perception pipeline that uses specialized models per modality, triggered intelligently — the way human perception works: fast pre-attentive local processing gates expensive focused cloud analysis.

---

## Architecture

```
┌──────────────────────────────────────────────┐
│  Frame Sources                                │
│  CameraCapture          ScreenCapture        │
│  (encode→JPEG)          (encode→JPEG)        │
│  (dedup check)          (dedup check)        │
└──────────────┬───────────────────────────────┘
               │ JPEG Data
               ▼
┌──────────────────────────────────────────────┐
│  LocalPerception  (Apple Vision)             │  ← ~20-50ms, local
│  VNImageRequestHandler(data: jpegData)       │
│  face · body pose · hand pose                │
│  OCR · scene class · human detect           │
└──────────────┬───────────────────────────────┘
               │ (jpegData, source, [PerceptionEvent])
               ▼
┌──────────────────────────────────────────────┐
│  PerceptionRouter  (actor)                   │  ← throttles + dispatches
└──────┬──────────┬──────────────┬─────────────┘
       ▼          ▼              ▼
   Hume AI    GPT-4o         GPT-4o
  emotions  activity/gesture  screen
       │          │              │
       └──────────┼──────────────┘
                  ▼
┌──────────────────────────────────────────────┐
│  PerceptionContext  (actor)                  │
│  face · emotion · pose · gesture             │
│  screen · activity                           │
└──────────────────────────────────────────────┘
                  │
                  ▼
               Logger
```

**AXReader** remains a standalone side-channel — logs directly to Logger on focus-change events, unchanged. It does not feed into PerceptionContext.

---

## Buffer Lifecycle

`AVFoundation` and `SCStream` recycle sample buffers after the delegate callback returns. Both capture classes already solve this by encoding to JPEG **inside the callback** before the buffer is released. This pattern is preserved — `LocalPerception` receives safe, owned `Data` (JPEG), not a raw `CVPixelBuffer`. `VNImageRequestHandler` accepts JPEG data directly.

---

## Components

### FrameProcessor Protocol

`CameraCapture` and `ScreenCapture` depend on this protocol, replacing the current `LocalVision` dependency:

```swift
protocol FrameProcessor {
    func process(jpegData: Data, source: String)
}
```

`LocalPerception` conforms to `FrameProcessor`. Calls are fire-and-forget from the capture layer.

---

### Deduplicator

**Kept in the capture layer** (current position). Deduplication happens before JPEG encoding to avoid wasted encode work. If a frame is a duplicate, neither JPEG encoding nor LocalPerception is invoked — same as today.

---

### LocalPerception

Conforms to `FrameProcessor`. Creates a `VNImageRequestHandler(data: jpegData, options: [:])` per frame and performs all applicable requests in one pass.

**Camera frame requests:**
- `VNDetectFaceRectanglesRequest` + `VNDetectFaceLandmarksRequest`
- `VNDetectHumanBodyPoseRequest`
- `VNDetectHumanHandPoseRequest`
- `VNDetectHumanRectanglesRequest`
- `VNClassifyImageRequest`

**Screen frame requests:**
- `VNRecognizeTextRequest` (accurate mode, confidence ≥ 0.5)
- `VNClassifyImageRequest`

After the handler completes, LocalPerception calls `router.dispatch(jpegData:source:events:)` on `PerceptionRouter`.

**PerceptionEvent enum:**
```swift
enum PerceptionEvent {
    case faceDetected(observation: VNFaceObservation)
    case bodyPoseDetected(observation: VNHumanBodyPoseObservation)
    case handPoseDetected(observation: VNHumanHandPoseObservation)
    case humanPresent
    case textRecognized(lines: [String])            // confidence ≥ 0.5, top-to-bottom
    case sceneClassified(labels: [(identifier: String, confidence: Float)])
    case nothingDetected
}
```

---

### PerceptionRouter

Declared as an `actor` — camera and screen frames arrive on separate queues; actor isolation prevents data races on throttle state and context writes.

```swift
actor PerceptionRouter {
    private var lastFired: [String: Date] = [:]    // throttle timestamps, keyed by analyzer name
    private let context: PerceptionContext
    private let hume: HumeEmotionAnalyzer?         // nil if HUME_API_KEY missing
    private let activity: GPT4oActivityAnalyzer?
    private let gesture: GPT4oGestureAnalyzer?
    private let screen: GPT4oScreenAnalyzer?
}
```

**`dispatch(jpegData:source:events:)`** checks each routing rule, fires eligible analyzers as `Task { }` (non-blocking), updates `lastFired`.

**Routing rules:**
| Condition | Analyzer | Throttle |
|---|---|---|
| `.faceDetected` (camera) | `HumeEmotionAnalyzer` | 2s |
| `.bodyPoseDetected` or `.handPoseDetected` | `GPT4oGestureAnalyzer` | 3s |
| `.faceDetected` or `.humanPresent` (camera) | `GPT4oActivityAnalyzer` | 5s |
| `.textRecognized` (screen) | `GPT4oScreenAnalyzer` | 4s |

`GPT4oActivityAnalyzer` is gated on human presence — does not fire for empty-room camera frames.

---

### Cloud Analyzers

**Protocol:**
```swift
protocol CloudAnalyzer {
    // jpegData is nil for text-only analyzers (GPT4oScreenAnalyzer)
    // Analyzers that require an image must treat nil as a no-op and return nil
    func analyze(jpegData: Data?, events: [PerceptionEvent]) async -> PerceptionObservation?
}
```

**Error policy (all analyzers):** On any network error, HTTP error (including 429), or timeout — log a `[warn]` line and return `nil`. No retry. `PerceptionContext` retains its previous state silently. This is acceptable for a perception layer.

---

**HumeEmotionAnalyzer**
- Requires `jpegData` non-nil (face crop). Returns `nil` if `jpegData` is nil.
- Crops the face using `VNFaceObservation.boundingBox`. Vision bounding boxes use **bottom-left origin** with normalized coordinates — Y must be flipped (`1 - y - height`) before cropping from the JPEG.
- API: Hume AI Expression Measurement
- Output: `EmotionState` — top 5 emotions with scores

**GPT4oActivityAnalyzer**
- Requires `jpegData` non-nil (full camera frame). Returns `nil` if nil.
- API: OpenAI `/v1/chat/completions`, `gpt-4o`, vision input
- Output: `ActivityState` — 1-2 sentence description of what the person is doing

**GPT4oGestureAnalyzer**
- Requires `jpegData` non-nil. Returns `nil` if nil.
- Extracts keypoint coordinates from `bodyPoseDetected`/`handPoseDetected` events, serializes as JSON, includes in system prompt alongside the image.
- API: OpenAI `/v1/chat/completions`, `gpt-4o`, vision input
- Output: `GestureState` — interpreted posture/gesture (e.g. "leaning back, arms crossed")

**GPT4oScreenAnalyzer**
- `jpegData` is always `nil` — text-only call (cheaper, faster).
- Input: OCR lines from `.textRecognized` joined with newlines as user message.
- API: OpenAI `/v1/chat/completions`, `gpt-4o`, text only
- Output: `ScreenState` — what the user is reading or working on

---

### PerceptionContext

Swift `actor`. Each cloud analyzer calls `context.update(...)` after receiving a result.

```swift
actor PerceptionContext {
    var face:     FaceState?
    var emotion:  EmotionState?
    var pose:     PoseState?
    var gesture:  GestureState?
    var screen:   ScreenState?
    var activity: ActivityState?

    // Called from main.swift after init
    func startSnapshotTimer(logger: Logger)
}
```

**State type definitions:**
```swift
struct FaceState     { let boundingBox: CGRect; let landmarksDetected: Bool; let updatedAt: Date }
struct EmotionState  { let emotions: [(label: String, score: Float)]; let updatedAt: Date }
struct PoseState     { let bodyPoints: [String: CGPoint]; let handPoints: [String: CGPoint]?; let updatedAt: Date }
struct GestureState  { let description: String; let updatedAt: Date }
struct ScreenState   { let ocrLines: [String]; let interpretation: String; let updatedAt: Date }
struct ActivityState { let description: String; let updatedAt: Date }
```

**Snapshot timer:** Owned by `PerceptionContext`, started via `startSnapshotTimer(logger:)` called from `main.swift` after wiring. Fires every **2 seconds** — matching the fastest cloud modality (Hume at 2s throttle), so the log is never more than one cycle stale. Serializes all non-nil state fields to a single JSON log line via `[source: perception]`.

---

### Environment Variables

Read at startup:
```
HUME_API_KEY=...
OPENAI_API_KEY=...
```

If `HUME_API_KEY` is absent: `HumeEmotionAnalyzer` is not created; `emotion` field in context remains nil.
If `OPENAI_API_KEY` is absent: all three GPT-4o analyzers are not created; `activity`, `gesture`, `screen` fields remain nil.
Each missing key emits one `[warn]` log at startup. LocalPerception (Apple Vision) always runs.

---

## Integration with Existing Code

| File | Change |
|---|---|
| `LocalVision.swift` | **Replaced** by `LocalPerception.swift` + 4 cloud analyzer files + `PerceptionRouter.swift` |
| `CameraCapture.swift` | Dependency: `LocalVision` → `FrameProcessor` protocol (drop-in, same call site) |
| `ScreenCapture.swift` | Dependency: `LocalVision` → `FrameProcessor` protocol (drop-in, same call site) |
| `Deduplicator.swift` | Kept, unchanged, in capture layer as today |
| `AXReader.swift` | Unchanged |
| `Logger.swift` | Unchanged |
| `main.swift` | Updated: construct `PerceptionContext`, `PerceptionRouter`, `LocalPerception`; call `context.startSnapshotTimer(logger:)`; pass `LocalPerception` as `FrameProcessor` to captures |

---

## Performance

- **LocalPerception:** ~20-50ms, all VN requests batched in one handler pass
- **Cloud calls:** non-blocking `Task { }`, frame processing never waits
- **Throttling:** independent per-analyzer intervals, owned by `PerceptionRouter` actor
- **Deduplication:** duplicate frames skip JPEG encode and all processing
- **Net result:** faster and cheaper than current Moondream approach (5s blocking semaphore per frame)

---

## Out of Scope

- What the assistant does with PerceptionContext observations
- Summarization, memory, proactive responses
- UI / output layer
- AX deduplication
