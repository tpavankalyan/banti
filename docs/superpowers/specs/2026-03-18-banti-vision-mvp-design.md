# Banti Vision MVP — Design Spec

**Date:** 2026-03-18
**Status:** Approved
**Scope:** Vision perception pipeline — input extraction and local inference only

---

## Overview

Banti is a personal AI assistant for macOS that is always on, passively watching and listening, and proactively assists without being asked. This spec covers the first stage: building the vision input pipeline.

The MVP captures screen and camera frames plus the macOS accessibility tree, deduplicates frames locally, passes them to a local vision model, and logs what the model sees. No cloud APIs, no TTS, no action layer — just perception to local inference to output.

---

## Goals

- Capture screen and camera continuously at low frame rate
- Extract structured UI context from the accessibility tree
- Avoid redundant inference by deduplicating unchanged frames
- Pass frames to a local vision model and log its descriptions
- Establish the foundation for all future banti perception work

## Non-Goals (this stage)

- Cloud LLM reasoning
- Text-to-speech or any audio output
- Tool use or action execution
- Memory or persistence
- Any UI beyond terminal logging

---

## Architecture

```
Screen (ScreenCaptureKit, 1fps)  ──┐
Camera (AVFoundation, 1fps)        ├──► Deduplicator ──► LocalVision ──► Logger
AX tree (event-driven)  ───────────┘     (dHash)        (Ollama/Moondream2)
```

---

## Target Hardware

Apple Silicon (M1 or later) is required. Intel Macs are not supported for this stage due to Moondream2 inference latency (8–15s on CPU vs. ~2s on Apple Silicon via Metal).

---

## Deployment Target

This is a macOS `.app` bundle (not a CLI tool). An app bundle is required for ScreenCaptureKit permission prompts to work correctly. `Info.plist` must include:
- `NSScreenCaptureUsageDescription`
- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription` (reserved for future audio stage)

The app is not sandboxed. Accessibility permission is granted via System Settings → Privacy & Security → Accessibility.

---

## Threading Model

- **ScreenCapture** delivers frames on a SCKit-managed internal queue. dHash is computed on this queue immediately and synchronously; the `CVPixelBuffer` is not retained beyond the callback.
- **CameraCapture** delivers frames on a dedicated serial `DispatchQueue` named `banti.camera`. dHash computed synchronously before the buffer is released.
- **AXReader** observer runs on the main `CFRunLoop` (via `CFRunLoopGetMain()`).
- **LocalVision** dispatches each Ollama HTTP request onto a shared `DispatchQueue` named `banti.inference` (concurrent). Max concurrency of 2 is enforced via a `DispatchSemaphore(value: 2)` — frames that cannot acquire the semaphore immediately are dropped. JPEG encoding happens on the capture queue before dispatch; only the `Data` blob is passed across.
- **Logger** writes to stdout on a dedicated serial `DispatchQueue` named `banti.logger` to prevent interleaved output.

No shared mutable state crosses queue boundaries except via explicit capture of value types or `Sendable`-conforming types.

---

## Components

### 1. ScreenCapture

- Uses `SCStream` from ScreenCaptureKit (macOS 14+)
- Configured at 1fps via `SCStreamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 1)`
- Delivers `CVPixelBuffer` frames via `SCStreamOutput` delegate
- **Primary display:** identified by matching `SCDisplay` against `NSScreen.main` via display ID
- Excludes no windows by default
- **Permission handling:** calls `SCShareableContent.getExcludingDesktopWindows` at launch; if it throws (permission denied or not yet granted), logs `[error] Screen recording permission denied — screen capture disabled` and continues without screen capture. Does not exit.

### 2. CameraCapture

- Uses `AVCaptureSession` with `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)`
- `AVCaptureVideoDataOutput` with delegate on `banti.camera` queue for continuous frame callbacks
- Throttled to 1fps by comparing `CMSampleBuffer` presentation timestamps; frames within 1 second of the last processed frame are dropped
- **Permission handling:** calls `AVCaptureDevice.requestAccess(for: .video)` at launch; session configuration occurs inside the completion handler only on `.authorized` status. If denied, logs `[error] Camera permission denied — camera capture disabled` and continues without camera. Does not exit.
- Session preset: `.medium` (640x480)

### 3. AXReader

- Uses `AXUIElement` accessibility APIs; observer registered on `CFRunLoopGetMain()`
- Listens for `kAXFocusedWindowChangedNotification` and `kAXApplicationActivatedNotification` via `AXObserver`
- **Permission handling:** checks `AXIsProcessTrusted()` at launch; if false, logs `[error] Accessibility permission not granted — AX reader disabled` and skips AX setup. Does not exit.
- On trigger: walks the AX tree of the focused app with **max depth: 3 levels, max elements: 50**. Extracts role, title, and value of each element. Stops early if limits are reached.
- Output: a flat string summary — app name, window title, and up to 50 element descriptions
- AX summaries are logged directly without passing through LocalVision

### 4. Deduplicator

- Computes a **difference hash (dHash)** for each incoming `CVPixelBuffer`
- dHash algorithm: downscale to 9x8 grayscale, compare adjacent pixel columns, produce a 64-bit hash
- Compares against the previous hash for the same source (screen and camera tracked in separate stored values)
- Skips the frame if Hamming distance is **≤ 10 bits** (out of 64)
- Hash and comparison computed synchronously on the capture queue before any dispatch

### 5. LocalVision

- **Startup check:** at launch, sends a `GET http://localhost:11434/api/tags` request. If it fails (connection refused or timeout), logs `[error] Ollama not running at localhost:11434 — vision inference disabled` and disables LocalVision. Does not exit. Rechecks every 30 seconds and re-enables if Ollama becomes available.
- Sends frames to `POST http://localhost:11434/api/generate`
- Model: `moondream`
- Frame JPEG-encoded (quality 0.7) on the capture queue and passed as `Data`; base64-encoded in the request body
- Prompt: `"Describe what you see concisely. Focus on what the user is doing."`
- **Timeouts:** The first request after startup (or after Ollama becomes available via the 30s recheck) uses a **15-second timeout** to cover Ollama's cold-start model loading delay. All subsequent requests use a **5-second timeout**. Timed-out requests are dropped with a `[warn] inference timeout (source: screen|camera)` log entry.
- Screen and camera frames sent independently; source label included in the log, not the prompt
- Max 2 concurrent inference requests (enforced via `DispatchSemaphore(value: 2)`)

### 6. Logger

- Writes to stdout on `banti.logger` serial queue
- Format: `[ISO8601 timestamp] [source: screen|camera|ax] <model response or AX summary>`
- Example: `[2026-03-18T14:23:01.123Z] [source: screen] User is editing a Swift file in Xcode. The editor shows a function named captureFrame.`
- AX events logged immediately without going through LocalVision

---

## Data Flow

1. `ScreenCapture` and `CameraCapture` emit frames at ~1fps on background queues
2. Each frame passes through `Deduplicator`; identical frames are dropped
3. Changed frames are JPEG-encoded and sent to `LocalVision`
4. `LocalVision` calls Ollama and receives a text description
5. `Logger` prints the description with source and timestamp
6. `AXReader` fires independently on focus events, logging AX summaries directly

---

## Tech Stack

| Component | Technology |
|---|---|
| Language | Swift 5.9+ |
| Platform | macOS 14+ (Sonoma) |
| Screen capture | ScreenCaptureKit (`SCStream`) |
| Camera capture | AVFoundation (`AVCaptureSession`) |
| Accessibility | AXUIElement / AXObserver |
| Local vision model | Moondream2 via Ollama |
| Build | Swift Package Manager |

---

## Dependencies

- **Ollama** running locally: `brew install ollama && ollama pull moondream`
- No Swift package dependencies beyond Apple frameworks

---

## Permissions Required

- Screen Recording (prompted via ScreenCaptureKit)
- Camera (prompted via AVFoundation)
- Accessibility (prompted via AXUIElement)

---

## Memory Management

- `CVPixelBuffer` objects must not be retained beyond the capture callback. JPEG encoding is synchronous on the capture queue; only the resulting `Data` is passed to `LocalVision`.
- No frame buffer queue is maintained. If `banti.inference` is at capacity (2 concurrent tasks), new frames are dropped silently — inference is always best-effort.
- The app must show no unbounded memory growth over a 10-minute run on Activity Monitor.

---

## Success Criteria

- Screen and camera frames captured continuously at ~1fps on Apple Silicon
- Duplicate frames are skipped (log frequency drops when screen is static)
- Moondream2 descriptions appear in the log within ~3 seconds of a screen change (Apple Silicon M1+)
- AX context logged on every app/window switch
- Process runs stably for 10+ minutes without crash or unbounded memory growth
- Graceful degradation: if any permission is denied or Ollama is not running, the remaining subsystems continue operating and errors are clearly logged

---

## Future Stages (out of scope here)

- Stage 2: Cloud LLM reasoning layer (Claude/GPT-4o) triggered by local model output
- Stage 3: Proactivity engine — banti decides when to speak
- Stage 4: TTS output
- Stage 5: Tool use and action layer
- Stage 6: Memory and persistence
- Stage 7: Audio perception (speech, speaker ID, emotion)
- Stage 8: Hardware (wearable) port
