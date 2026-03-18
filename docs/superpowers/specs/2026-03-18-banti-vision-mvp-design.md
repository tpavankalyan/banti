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
AX tree (event-driven)  ───────────┘     (pHash)        (Ollama/Moondream2)
```

---

## Components

### 1. ScreenCapture

- Uses `SCStream` from ScreenCaptureKit (macOS 12.3+, required macOS 14+)
- Configured at 1fps via `SCStreamConfiguration.minimumFrameInterval`
- Delivers `CVPixelBuffer` frames via `SCStreamOutput` delegate
- Requests screen recording permission at launch via `SCShareableContent`
- Captures the primary display; excludes no windows by default

### 2. CameraCapture

- Uses `AVCaptureSession` with `AVCaptureDevice` (built-in webcam)
- `AVCaptureVideoDataOutput` with delegate for continuous frame callbacks
- Throttled to 1fps by dropping frames in the delegate based on timestamp delta
- Requests camera permission at launch via `AVCaptureDevice.requestAccess`
- Session preset: `AVCaptureSession.Preset.medium` (640x480, sufficient for local model)

### 3. AXReader

- Uses `AXUIElement` accessibility APIs
- Listens for `kAXFocusedWindowChangedNotification` and `kAXApplicationActivatedNotification` via `AXObserver`
- On trigger: walks the AX tree of the focused app and extracts title, role, and visible text of key elements
- Output: a flat string summary of the current UI context (app name, window title, focused element)
- Requires Accessibility permission (prompted at launch)

### 4. Deduplicator

- Computes a perceptual hash (pHash) for each incoming `CVPixelBuffer`
- Compares against the previous hash for the same source (screen vs. camera tracked separately)
- Skips the frame if Hamming distance is below threshold (default: 10 bits)
- pHash computed on a downscaled 32x32 grayscale version of the frame for speed

### 5. LocalVision

- Sends frames to Ollama HTTP API (`http://localhost:11434/api/generate`)
- Model: `moondream` (pulled via `ollama pull moondream`)
- Frame encoded as JPEG (quality 0.7) and base64-encoded before sending
- Prompt: `"Describe what you see concisely. Focus on what the user is doing."`
- Requests are fire-and-forget with a 5-second timeout; slow responses are dropped
- Screen and camera frames sent independently with source label in prompt

### 6. Logger

- Prints structured output to stdout
- Format: `[timestamp] [source: screen|camera|ax] <model response or AX summary>`
- AX events logged immediately without going through LocalVision (text-only, no vision model needed)

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

## Success Criteria

- Screen and camera frames captured continuously at ~1fps
- Duplicate frames are skipped (verifiable by log frequency dropping when screen is static)
- Moondream2 descriptions appear in the terminal log within ~3 seconds of a screen change
- AX context logged on every app/window switch
- Process runs stably for 10+ minutes without crash or memory growth

---

## Future Stages (out of scope here)

- Stage 2: Cloud LLM reasoning layer (Claude/GPT-4o) triggered by local model output
- Stage 3: Proactivity engine — banti decides when to speak
- Stage 4: TTS output
- Stage 5: Tool use and action layer
- Stage 6: Memory and persistence
- Stage 7: Audio perception (speech, speaker ID, emotion)
- Stage 8: Hardware (wearable) port
