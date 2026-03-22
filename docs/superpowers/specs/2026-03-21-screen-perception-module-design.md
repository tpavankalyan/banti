# Screen Perception Module Design

**Date:** 2026-03-21
**Status:** Approved — Implemented
**Module:** Perception — Screen Capture + Active App Tracking
**Target:** macOS 14+ (Sonoma), Swift 5.9+, Xcode project (`.xcodeproj`)

---

## 1. Goal

Add a Screen perception pipeline to Banti, mirroring the Camera pipeline architecture. Two actors are introduced:

- `ScreenCaptureActor` — continuously captures the primary display as JPEG frames using ScreenCaptureKit and publishes `ScreenFrameEvent` to EventHub.
- `ScreenDescriptionActor` — subscribes to `ScreenFrameEvent`, self-throttles, calls `VisionProvider` (same protocol used by `SceneDescriptionActor`), and publishes `ScreenDescriptionEvent`.
- `ActiveAppActor` — independently observes `NSWorkspace` for frontmost application changes and publishes `ActiveAppEvent` whenever the user switches apps.

The design is explicitly extensible: future actors (OCR, UI element detection, browser URL extraction) subscribe to `ScreenFrameEvent` independently, with no changes to the capture layer.

---

## 2. Architecture

### 2.1 New Modules (BantiModule conformers)

| Actor | Role |
|---|---|
| `ScreenCaptureActor` | Captures primary display frames via ScreenCaptureKit, publishes `ScreenFrameEvent` |
| `ScreenDescriptionActor` | Throttles frames → VisionProvider → publishes `ScreenDescriptionEvent` |
| `ActiveAppActor` | Observes NSWorkspace, publishes `ActiveAppEvent` on frontmost app change |

### 2.2 Pipeline

```
ScreenCaptureKit (display hardware)
    │ SCStream sample handler → JPEG compression → ScreenLatestFrameBuffer
    ▼
ScreenCaptureActor         → publishes ScreenFrameEvent every SCREEN_CAPTURE_INTERVAL_MS (default 1000ms)
    │ (EventHub)
    ▼
ScreenDescriptionActor     → self-throttles to SCREEN_DESCRIPTION_INTERVAL_S (default 10s)
                           → calls VisionProvider.describe(jpeg:, prompt:)
                           → publishes ScreenDescriptionEvent (text, captureTime, responseTime)
    │ (EventHub)
    ▼
EventLoggerActor + EventLogViewModel  (observers — no Brain actor yet)

NSWorkspace (system events)
    ▼
ActiveAppActor             → publishes ActiveAppEvent on frontmost app change
    │ (EventHub)
    ▼
EventLoggerActor + EventLogViewModel  (observers)
```

> **Note:** BrainActor has been removed. `ScreenDescriptionEvent` and `ActiveAppEvent` are currently consumed only by the logger and the UI feed. Future Brain integration will subscribe here.

Existing camera pipeline for reference:
```
CameraFrameActor → CameraFrameEvent → SceneDescriptionActor → SceneDescriptionEvent
```

---

## 3. Component Interfaces

### 3.1 ScreenCaptureActor

```swift
actor ScreenCaptureActor: BantiModule {
    nonisolated let id = ModuleID("screen-capture")
    nonisolated let capabilities: Set<Capability> = [.screenCapture]

    init(eventHub: EventHubActor, config: ConfigActor)
    func start() async throws   // requests SC permission, starts SCStream
    func stop() async
    func health() async -> ModuleHealth
}
```

**Thread bridging:** SCStream's `stream(_:didOutputSampleBuffer:of:)` delegate runs on a background thread. The delegate compresses the `CMSampleBuffer` to JPEG and writes it into `ScreenLatestFrameBuffer` (single-slot, same pattern as `CameraLatestFrameBuffer`). A drain `Task` inside `ScreenCaptureActor` reads the buffer at `SCREEN_CAPTURE_INTERVAL_MS` and publishes `ScreenFrameEvent`.

**Permission handling:** ScreenCaptureKit requires explicit user approval via `SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true)`. If the system returns a permission error, `health()` returns `.failed` and the module does not retry without a restart.

**Display selection:** Captures the main display (`NSScreen.main`) by default. Configurable via `SCREEN_CAPTURE_DISPLAY_INDEX` env key.

### 3.2 ScreenDescriptionActor

Identical structure to `SceneDescriptionActor`. Subscribes to `ScreenFrameEvent` instead of `CameraFrameEvent`, publishes `ScreenDescriptionEvent`.

```swift
actor ScreenDescriptionActor: BantiModule {
    nonisolated let id = ModuleID("screen-description")
    nonisolated let capabilities: Set<Capability> = [.screenDescription]

    init(eventHub: EventHubActor, config: ConfigActor, provider: (any VisionProvider)? = nil)
    func start() async throws
    func stop() async
    func health() async -> ModuleHealth
}
```

The default prompt is configurable via `SCREEN_DESCRIPTION_PROMPT`. Default:
> "Describe what is shown on this computer screen. Focus on the application in use, visible text, open documents, and what the user appears to be doing."

**Reuses `VisionProvider` protocol and `ClaudeVisionProvider` without modification.**

### 3.3 ActiveAppActor

```swift
actor ActiveAppActor: BantiModule {
    nonisolated let id = ModuleID("active-app")
    nonisolated let capabilities: Set<Capability> = [.activeAppTracking]

    init(eventHub: EventHubActor)
    func start() async throws   // registers NSWorkspace.didActivateApplicationNotification observer
    func stop() async            // removes observer
    func health() async -> ModuleHealth
}
```

Uses `NotificationCenter.default` with `NSWorkspace.didActivateApplicationNotification`. The notification is received on the main thread; the actor dispatches an async `Task` to publish `ActiveAppEvent` to EventHub. No polling — purely event-driven.

On `start()`, immediately publishes an `ActiveAppEvent` for the current frontmost app so Brain has an initial context snapshot.

---

## 4. Event Contracts

All event definitions live in `Core/Events/`.

### 4.1 ScreenFrameEvent

```swift
struct ScreenFrameEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID          // "screen-capture"
    let jpeg: Data
    let sequenceNumber: UInt64
    let displayWidth: Int
    let displayHeight: Int
}
```

> **Implementation note:** `scaleFactor: CGFloat` was dropped from the final implementation. The JPEG is already downscaled to max 1920px on the longest edge at quality 0.6; consumers do not need the original Retina scale factor.

JPEG is downscaled to max 1920px on the longest edge at quality 0.6 before publishing.

### 4.2 ScreenDescriptionEvent

```swift
struct ScreenDescriptionEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID          // "screen-description"
    let text: String
    let captureTime: Date
    let responseTime: Date
}
```

### 4.3 ActiveAppEvent

```swift
struct ActiveAppEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID          // "active-app"
    let bundleIdentifier: String        // e.g. "com.apple.dt.Xcode"
    let appName: String                 // e.g. "Xcode"
    let previousBundleIdentifier: String?
    let previousAppName: String?
}
```

---

## 5. New Files

```
Banti/Banti/Modules/Perception/Screen/
    ScreenCaptureActor.swift         — SCStream capture, publishes ScreenFrameEvent
    ScreenDescriptionActor.swift     — throttle + VisionProvider call, publishes ScreenDescriptionEvent
    ActiveAppActor.swift             — NSWorkspace observer, publishes ActiveAppEvent

Banti/Banti/Core/
    ScreenLatestFrameBuffer.swift    — identical pattern to CameraLatestFrameBuffer; single-slot thread-safe

Banti/Banti/Core/Events/
    ScreenFrameEvent.swift
    ScreenDescriptionEvent.swift
    ActiveAppEvent.swift
```

New `Capability` constants added to `BantiModule.swift`:
```swift
static let screenCapture     = Capability("screen-capture")
static let screenDescription = Capability("screen-description")
static let activeAppTracking = Capability("active-app-tracking")
```

---

## 6. Configuration Keys

Added to `Environment.swift`:

| Key | Default | Description |
|---|---|---|
| `SCREEN_CAPTURE_INTERVAL_MS` | `1000` | How often ScreenCaptureActor publishes a frame |
| `SCREEN_DESCRIPTION_INTERVAL_S` | `10` | Minimum seconds between VLM calls |
| `SCREEN_DESCRIPTION_PROMPT` | (see §3.2) | System prompt sent to VisionProvider |
| `SCREEN_CAPTURE_DISPLAY_INDEX` | `0` | Which display to capture (0 = main) |

`VISION_PROVIDER` and `ANTHROPIC_API_KEY` are reused from the camera pipeline — no new keys needed for the VisionProvider.

---

## 7. Entitlements & Permissions

```xml
<!-- Banti.entitlements -->
<key>com.apple.security.screen-capture</key>
<true/>
```

```xml
<!-- Info.plist -->
<key>NSScreenCaptureUsageDescription</key>
<string>Banti captures your screen to understand what you are working on.</string>
```

ScreenCaptureKit on macOS 14 also requires the user to grant access in **System Settings → Privacy & Security → Screen & System Audio Recording**. First launch triggers the system prompt automatically when `SCShareableContent` is first called.

---

## 8. Error Handling

| Failure | Response |
|---|---|
| Screen recording permission denied | `.failed`, no retry, UI surfaces permission prompt |
| SCStream drops frames (system busy) | Drain task finds buffer empty; silently skips that interval; stays `.healthy` |
| Display disconnected | `.degraded`, supervisor restarts after backoff |
| VisionProvider error (screen) | `.degraded(reason:)`, logs error, resumes on next frame |
| NSWorkspace notification missing | `.degraded`, re-registers observer on next `start()` |

---

## 9. Startup Registration (BantiApp.swift additions)

```swift
let screenCapture = ScreenCaptureActor(eventHub: eventHub, config: config)
let screenDescription = ScreenDescriptionActor(eventHub: eventHub, config: config)
let activeApp = ActiveAppActor(eventHub: eventHub)

// screenDesc must be subscribed before screenCapture starts publishing frames.
await supervisor.register(activeApp,         restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
await supervisor.register(screenDescription, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
await supervisor.register(screenCapture,     restartPolicy: .onFailure(maxRetries: 3, backoff: 2),
                           dependencies: [screenDescription.id])
```

---

## 10. Testing Strategy

- **`ScreenCaptureActorTests`**: mock SCStream with a `ScreenLatestFrameBuffer` injected with test JPEGs; verify `ScreenFrameEvent` published with correct seq numbers.
- **`ScreenDescriptionActorTests`**: inject mock `VisionProvider`; verify throttling (no double-call within interval), health transitions on provider failure.
- **`ActiveAppActorTests`**: post synthetic `NSWorkspace.didActivateApplicationNotification` notifications; verify `ActiveAppEvent` payload and `previous*` fields on second switch.
- **Protocol conformance tests**: run existing `BantiModule` lifecycle test suite against all three new actors.

---

## 11. Dependencies

- **ScreenCaptureKit** (system framework, macOS 12.3+) — replaces deprecated `CGDisplayCreateImage`
- **AppKit / NSWorkspace** (system framework) — for `ActiveAppActor`
- **VisionProvider** (existing protocol) — no changes
- **No third-party dependencies**

---

## 12. Out of Scope

- System audio capture (separate spec)
- OCR / text extraction from screen (future `ScreenOCRActor` subscribes to `ScreenFrameEvent`)
- Multiple display capture
- Browser URL extraction (future AX-based actor in the Accessibility pipeline)
- Cursor position tracking
