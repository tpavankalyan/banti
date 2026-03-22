# Banti

An ambient AI assistant for macOS that mimics the human brain's perceptual system. Banti continuously observes its environment through multiple sensory channels — camera, screen, microphone, accessibility tree — and publishes structured events onto an internal event bus. Higher-level cognitive modules (planned) subscribe to those events to build context and act.

## Architecture overview

```
┌────────────────────── Perception Layer ─────────────────────────┐
│  CameraFrameActor     → CameraFrameEvent (5fps, JPEG)           │
│  SceneDescriptionActor → SceneDescriptionEvent (every 5s, VLM)  │
│                                                                   │
│  ScreenCaptureActor   → ScreenFrameEvent (1fps, JPEG)            │
│  ScreenDescriptionActor → ScreenDescriptionEvent (every 10s)     │
│  ActiveAppActor        → ActiveAppEvent (on app switch)          │
│                                                                   │
│  MicrophoneCaptureActor → AudioFrameEvent (100ms chunks)         │
│  DeepgramStreamingActor → RawTranscriptEvent (interim + final)   │
│  TranscriptProjectionActor → TranscriptSegmentEvent              │
│                                                                   │
│  AXFocusActor         → AXFocusEvent (focus/selection/value)     │
└───────────────────────────────┬─────────────────────────────────┘
                                │  EventHubActor  (typed pub/sub)
                  ┌─────────────┴──────────────┐
                  │                            │
         EventLoggerActor             EventLogViewModel
         (Console.app)                (SwiftUI window)
```

**Core infrastructure:**
- `EventHubActor` — type-safe, actor-isolated publish/subscribe bus with bounded per-subscriber queues
- `ModuleSupervisorActor` — topological module startup, rollback on failure, health polling
- `StateRegistryActor` — tracks per-module `ModuleHealth` (healthy / degraded / failed)
- `ConfigActor` — reads `.env` file + environment variables; used by all modules

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (to regenerate the `.xcodeproj` from `project.yml`)

## Setup

1. Clone the repo.

2. Copy the environment template and fill in your API keys:
   ```sh
   cp .env.example .env
   # Edit .env — add at minimum DEEPGRAM_API_KEY and ANTHROPIC_API_KEY
   ```

3. Generate the Xcode project (if needed):
   ```sh
   cd Banti
   xcodegen generate
   ```

4. Grant permissions on first launch:
   - **Microphone** — system dialog on first audio capture
   - **Camera** — system dialog on first camera capture
   - **Screen Recording** — System Settings → Privacy & Security → Screen & System Audio Recording
   - **Accessibility** — System Settings → Privacy & Security → Accessibility (required for `AXFocusActor`)

## Running

**Background (recommended for daily use):**
```sh
./run.sh
```
Builds in Debug, kills any existing instance, and launches in the background. Logs stream to Console.app — filter by `subsystem:com.banti` or `category:EventLog`.

**Foreground (for development / log streaming to terminal):**
```sh
./dev.sh
```
Builds in Debug and runs in the foreground — `Ctrl-C` to stop. All `os.Logger` output appears directly in the terminal.

## Configuration

All configuration is read from `.env` at startup (and falls back to process environment variables).

| Key | Default | Description |
|---|---|---|
| `DEEPGRAM_API_KEY` | _(required)_ | Deepgram WebSocket ASR |
| `ANTHROPIC_API_KEY` | _(required)_ | Anthropic API for vision descriptions |
| `DEEPGRAM_MODEL` | `nova-2` | Deepgram model |
| `DEEPGRAM_LANGUAGE` | `en` | Transcript language |
| `VISION_PROVIDER` | `claude` | Vision backend (`claude` only for now) |
| `ANTHROPIC_VISION_MODEL` | `claude-haiku-4-5` | Model used for scene/screen descriptions |
| `CAMERA_CAPTURE_INTERVAL_MS` | `200` | How often CameraFrameActor publishes a frame |
| `SCENE_DESCRIPTION_INTERVAL_S` | `5` | Minimum seconds between VLM calls for camera |
| `SCENE_DESCRIPTION_PROMPT` | _(see source)_ | Prompt sent to VLM for camera frames |
| `SCREEN_CAPTURE_INTERVAL_MS` | `1000` | How often ScreenCaptureActor publishes a frame |
| `SCREEN_DESCRIPTION_INTERVAL_S` | `10` | Minimum seconds between VLM calls for screen |
| `SCREEN_DESCRIPTION_PROMPT` | _(see source)_ | Prompt sent to VLM for screen frames |
| `AX_DEBOUNCE_MS` | `50` | Debounce window for `kAXValueChangedNotification` |
| `AX_SELECTED_TEXT_MAX_CHARS` | `2000` | Max selected-text length carried in `AXFocusEvent` |

## Project structure

```
Banti/
  Banti/
    BantiApp.swift              — App entry point, bootstrap wiring
    Config/
      ConfigActor.swift         — .env / env-var reader
      Environment.swift         — EnvKey constants
    Core/
      BantiModule.swift         — BantiModule protocol, ModuleID, Capability, ModuleHealth
      PerceptionEvent.swift     — PerceptionEvent protocol, SubscriptionID
      EventHubActor.swift       — Typed pub/sub bus
      EventLoggerActor.swift    — Console.app observer (all 10 event types)
      ModuleSupervisorActor.swift — Lifecycle, topology, health polling
      StateRegistryActor.swift  — Per-module health state
      AudioRingBuffer.swift     — Thread-safe accumulating audio buffer
      CameraLatestFrameBuffer.swift — Thread-safe single-slot camera frame buffer
      ScreenLatestFrameBuffer.swift — Thread-safe single-slot screen frame buffer
      Events/                   — One file per PerceptionEvent struct
    Modules/
      Perception/
        Camera/                 — CameraFrameActor, SceneDescriptionActor, VisionProvider
        Screen/                 — ScreenCaptureActor, ScreenDescriptionActor, ActiveAppActor
        Microphone/             — MicrophoneCaptureActor, DeepgramStreamingActor, TranscriptProjectionActor
        Accessibility/          — AXFocusActor, AXEventBridge
    UI/
      EventLogEntry.swift       — Identifiable value type for log rows
      EventLogViewModel.swift   — @MainActor subscriber + formatter
      EventLogView.swift        — SwiftUI live event feed
  BantiTests/                   — XCTest suite
docs/
  superpowers/
    specs/                      — Design documents
    plans/                      — Implementation plans
```

## Testing

```sh
cd Banti
xcodebuild test -project Banti.xcodeproj -scheme Banti \
  -destination 'platform=macOS,arch=arm64' -quiet
```

## Known limitations / planned work

- `RestartPolicy` is registered on each module but the supervisor's health-polling loop does not yet automatically restart failing modules — restarts are currently triggered only for `MicrophoneCaptureActor` on system wake. Automatic restart enforcement is a planned improvement.
- `BrainActor` (cognitive loop) and `SpeechActor` (TTS output) have been removed and will be re-added in a future phase once the perception foundation is stable.
- Only the primary display is captured. Multi-display support is out of scope.
- `SCREEN_CAPTURE_DISPLAY_INDEX` env key is in the spec but not yet implemented; the first display returned by `SCShareableContent` is always used.
