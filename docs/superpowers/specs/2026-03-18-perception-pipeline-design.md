# Banti Perception Pipeline Design

**Date:** 2026-03-18
**Status:** Approved
**Scope:** Perception layer only — how observations are gathered and structured. Output/assistant layer is out of scope.

---

## Goal

Replace the single Moondream model with a multi-modal perception pipeline that uses specialized models per modality, triggered intelligently — the way human perception works: fast pre-attentive local processing gates expensive focused cloud analysis.

---

## Architecture

Three layers:

```
┌──────────────────────────────────────┐
│  Frame Sources                        │
│  CameraCapture  ScreenCapture        │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  LocalPerception  (Apple Vision)      │  ← every frame, local, ~20-50ms
│  face · body pose · hand pose         │
│  OCR · scene class · human detect    │
└──────────────┬───────────────────────┘
               │ emits PerceptionEvents
       ┌───────┼───────┐
       ▼       ▼       ▼
   Hume AI  GPT-4o  GPT-4o          ← cloud, triggered selectively
  emotions  scene  gesture/screen
       │       │       │
       └───────┼───────┘
               ▼
┌──────────────────────────────────────┐
│  PerceptionContext  (Swift actor)     │  ← coherent current state
│  face · emotion · pose · gesture      │
│  screen · activity                    │
└──────────────────────────────────────┘
               │
               ▼
            Logger
```

---

## Components

### LocalPerception

Runs a `VNImageRequestHandler` on every frame using Apple Vision. Batches multiple requests in a single pass for efficiency. Emits `PerceptionEvent` values to the router.

**Camera frame requests:**
- `VNDetectFaceRectanglesRequest` + `VNDetectFaceLandmarksRequest` — face presence and geometry
- `VNDetectHumanBodyPoseRequest` — 17-point body skeleton
- `VNDetectHumanHandPoseRequest` — 21-point hand skeleton
- `VNDetectHumanRectanglesRequest` — human presence (cheaper fallback when no face)
- `VNClassifyImageRequest` — scene/object labels

**Screen frame requests:**
- `VNRecognizeTextRequest` (accurate mode) — OCR, best-in-class accuracy, fully local
- `VNClassifyImageRequest` — scene labels

**PerceptionEvent enum:**
```swift
enum PerceptionEvent {
    case faceDetected(landmarks: VNFaceLandmarksObservation)
    case bodyPoseDetected(observation: VNHumanBodyPoseObservation)
    case handPoseDetected(observation: VNHumanHandPoseObservation)
    case textRecognized(lines: [String])
    case sceneClassified(labels: [(identifier: String, confidence: Float)])
    case humanPresent
    case nothingDetected
}
```

---

### PerceptionRouter

Receives `(frame: Data, source: String, events: [PerceptionEvent])` from LocalPerception. Decides which cloud analyzers to trigger based on what was detected, subject to per-analyzer throttle intervals.

**Routing rules:**
| Event | Cloud Analyzer Triggered | Throttle |
|---|---|---|
| `.faceDetected` | HumeEmotionAnalyzer | 2s |
| `.bodyPoseDetected` or `.handPoseDetected` | GPT4oGestureAnalyzer | 3s |
| Camera frame (any) | GPT4oActivityAnalyzer | 5s |
| `.textRecognized` | GPT4oScreenAnalyzer | 4s |

All cloud calls are non-blocking — the router fires them and continues immediately.

---

### Cloud Analyzers

Each conforms to a simple protocol:

```swift
protocol CloudAnalyzer {
    func analyze(frame: Data, events: [PerceptionEvent]) async throws -> PerceptionObservation
}
```

**HumeEmotionAnalyzer**
- API: Hume AI Expression Measurement (`/batch/jobs` or streaming endpoint)
- Input: JPEG face crop (cropped to face bounding box from VNFaceObservation)
- Output: top N emotions with confidence scores
- Trigger: `.faceDetected` only — never runs without a confirmed face

**GPT4oActivityAnalyzer**
- API: OpenAI `/v1/chat/completions` with `gpt-4o`, vision input
- Input: full camera frame + prompt asking for activity description
- Output: 1-2 sentence description of what the person is doing
- Trigger: camera frames, throttled to every 5s

**GPT4oGestureAnalyzer**
- API: OpenAI `/v1/chat/completions` with `gpt-4o`, vision input
- Input: camera frame + serialized body/hand keypoints as context in prompt
- Output: interpreted gesture/posture meaning (e.g. "leaning back, arms crossed, thinking")
- Trigger: `.bodyPoseDetected` or `.handPoseDetected`, throttled to every 3s

**GPT4oScreenAnalyzer**
- API: OpenAI `/v1/chat/completions` with `gpt-4o`, text input only (no image)
- Input: OCR text lines from `VNRecognizeTextRequest`
- Output: what the user is reading/working on, key content
- Trigger: `.textRecognized`, throttled to every 4s
- Note: text-only call is cheaper and faster than vision call

---

### PerceptionContext

A Swift `actor` holding the latest observation from each modality. Thread-safe by construction.

```swift
actor PerceptionContext {
    var face:     FaceState?
    var emotion:  EmotionState?
    var pose:     PoseState?
    var gesture:  GestureState?
    var screen:   ScreenState?
    var activity: ActivityState?
}

struct EmotionState {
    let emotions: [(label: String, score: Float)]
    let updatedAt: Date
}
// (similar structure for each state type)
```

Every 5 seconds, the context is serialized to a single structured log line — a snapshot of the full perception state. Individual modality updates are not logged separately.

---

### Environment Variables

API keys are read from environment at startup:

```
HUME_API_KEY=...
OPENAI_API_KEY=...
```

If a key is missing, the corresponding cloud analyzer is disabled with a warning log. Local (Apple Vision) analyzers always run.

---

## Integration with Existing Code

- `LocalVision.swift` (Moondream client) → **replaced** by `LocalPerception.swift` + cloud analyzers
- `Deduplicator.swift` → **kept** — still deduplicates frames before they enter LocalPerception
- `CameraCapture.swift`, `ScreenCapture.swift`, `AXReader.swift`, `Logger.swift` → **kept unchanged**
- `main.swift` → updated to wire new components

---

## Performance

- **LocalPerception:** ~20-50ms per frame on Apple Silicon Neural Engine, batched in one handler pass
- **Cloud calls:** async, non-blocking — frame processing never waits for cloud results
- **Throttling:** each analyzer has an independent minimum interval, prevents API pile-up
- **Net result:** faster and cheaper than current blocking Moondream approach (which held a semaphore for up to 5s per frame)

---

## Out of Scope

- What the assistant does with `PerceptionContext` observations
- Summarization, memory, proactive responses
- UI / output layer
- AX deduplication (separate task)
