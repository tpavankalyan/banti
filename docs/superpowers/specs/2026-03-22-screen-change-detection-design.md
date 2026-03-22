# Screen Change Detection Design

**Date:** 2026-03-22
**Status:** Approved
**Module:** Perception — Screen

---

## 1. Goal

Replace the time-based throttle in `ScreenDescriptionActor` with perceptual change-gating, mirroring the camera pipeline's `SceneChangeDetectionActor`. A new `ScreenChangeDetectionActor` sits between `ScreenCaptureActor` and `ScreenDescriptionActor` and only forwards frames when the screen has changed meaningfully. This makes VLM calls event-driven (fired by actual content change) rather than clock-driven.

---

## 2. Architecture

### 2.1 Pipeline Change

```
Before:
ScreenCaptureActor → ScreenFrameEvent → ScreenDescriptionActor (time-throttled, every 10s)

After:
ScreenCaptureActor → ScreenFrameEvent → ScreenChangeDetectionActor → ScreenChangeEvent → ScreenDescriptionActor (no throttle)
```

### 2.2 New Components

| Component | Role |
|---|---|
| `ScreenChangeDetectionActor` | Subscribes to `ScreenFrameEvent`, computes perceptual distance via `VNFeaturePrintObservation`, publishes `ScreenChangeEvent` when `distance >= threshold` |
| `ScreenChangeEvent` | New event type carrying jpeg + changeDistance + metadata |

### 2.3 Modified Components

| Component | Change |
|---|---|
| `ScreenDescriptionActor` | Subscribes to `ScreenChangeEvent` instead of `ScreenFrameEvent`; time-throttle logic removed; `changeDistance` included in published `ScreenDescriptionEvent` |
| `BantiApp.swift` | Wires `ScreenChangeDetectionActor` between `ScreenCaptureActor` and `ScreenDescriptionActor` |

---

## 3. Component Interfaces

### 3.1 ScreenFrameDifferencer (new, screen-local)

Defined in `Screen/ScreenFrameDifferencer.swift` — a direct port of `Camera/FrameDifferencer.swift` with no cross-module sharing. Identical structure: a `ScreenFrameDifferencer` protocol and a `VNScreenFrameDifferencer` production actor.

```swift
protocol ScreenFrameDifferencer: Actor {
    /// Returns nil on first call (no prior reference), distance [0, ∞) on subsequent calls.
    func distance(from jpeg: Data) throws -> Float?
}

actor VNScreenFrameDifferencer: ScreenFrameDifferencer {
    private var reference: VNFeaturePrintObservation?
    func distance(from jpeg: Data) throws -> Float? { ... } // identical logic to VNFrameDifferencer
}
```

This separate definition keeps the Camera and Screen pipelines independently ownable, while still providing the injection point needed for unit tests.

### 3.2 ScreenChangeDetectionActor

```swift
actor ScreenChangeDetectionActor: BantiModule {
    nonisolated let id = ModuleID("screen-change-detection")
    nonisolated let capabilities: Set<Capability> = [.screenChangeDetection]

    init(eventHub: EventHubActor, config: ConfigActor, differencer: (any ScreenFrameDifferencer)? = nil)
    func start() async throws
    func stop() async
    func health() async -> ModuleHealth
}
```

`differencer` defaults to `VNScreenFrameDifferencer()` if `nil` is passed (production path). Tests inject a `MockScreenFrameDifferencer` to return controlled distances without Vision framework.

**Behavior:**

- On `start()`: reads threshold via `await config.value(for: EnvKey.screenChangeThreshold)` (default `0.05`); if `SCREEN_DESCRIPTION_INTERVAL_S` is present in config, logs a one-time startup warning: `"SCREEN_DESCRIPTION_INTERVAL_S is no longer used — screen descriptions are now change-driven. Remove this key to suppress this warning."` Then subscribes to `ScreenFrameEvent`.
- For each frame: calls `differencer.distance(from: event.jpeg)`
- First frame: `distance` returns `nil` → always publishes; `changeDistance` in event is `nil`
- Subsequent frames: publishes `ScreenChangeEvent` only when `distance >= threshold`; `changeDistance` carries the actual float value
- On `ScreenFrameDifferencer` error: logs, marks health `.degraded`, skips frame

**Threshold rationale:** Default `0.05` is lower than the camera's `0.15` to catch smaller changes such as new text appearing in a document, while still filtering out cursor movement, blinking carets, and minor animation noise.

### 3.3 ScreenDescriptionActor (modified)

- Subscribes to `ScreenChangeEvent` instead of `ScreenFrameEvent`
- Removes `lastDescribedAt` and `intervalS` time-throttle logic entirely
- Reads `event.changeDistance` from `ScreenChangeEvent` and passes it to the `ScreenDescriptionEvent(text:captureTime:responseTime:changeDistance:)` constructor — the existing call site must be updated to include this new argument
- **Replace** the existing `ScreenDescriptionEvent` memberwise `init(text:captureTime:responseTime:)` with `init(text:captureTime:responseTime:changeDistance:)` — the old two-argument form must be removed so no caller can omit `changeDistance`
- All other behavior unchanged (VisionProvider call, prompt, error handling, health transitions)
- **No replay provider:** unlike `SceneDescriptionActor`, no `replayProvider` parameter is needed — the screen pipeline has no replay mechanism

---

## 4. Event Contracts

### 4.1 ScreenChangeEvent (new)

```swift
struct ScreenChangeEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID          // "screen-change-detection"
    let jpeg: Data
    let changeDistance: Float?          // nil for first frame (no prior reference); raw measured distance for subsequent (>= threshold as a consequence of gating, not a type constraint)
    let sequenceNumber: UInt64          // from the source ScreenFrameEvent
    let captureTime: Date               // timestamp from the source ScreenFrameEvent
}
```

`changeDistance` is `Float?` (not `Float`) to faithfully represent "first frame / no reference" as distinct from a measured zero-distance frame. This matches the `VNScreenFrameDifferencer.distance()` return type and avoids ambiguity when `SCREEN_CHANGE_THRESHOLD=0.0`. **Note:** this is an intentional departure from `SceneChangeEvent`, which uses `Float` and collapses the first-frame case to `0.0` via `dist ?? 0`. The screen pipeline improves on that design.

### 4.2 ScreenDescriptionEvent (modified)

Add `changeDistance: Float?` field (same intentional `Float?` choice as `ScreenChangeEvent` — departure from `SceneDescriptionEvent`'s non-optional `Float`) and **replace** the existing memberwise `init` (removing the old three-argument form so no caller can accidentally omit `changeDistance`):

```swift
struct ScreenDescriptionEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID          // "screen-description"
    let text: String
    let captureTime: Date
    let responseTime: Date
    let changeDistance: Float?          // NEW: nil for first-frame descriptions; measured distance otherwise

    init(text: String, captureTime: Date, responseTime: Date, changeDistance: Float?) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("screen-description")
        self.text = text
        self.captureTime = captureTime
        self.responseTime = responseTime
        self.changeDistance = changeDistance
    }
}
```

---

## 5. New Files

```
Banti/Banti/Modules/Perception/Screen/
    ScreenChangeDetectionActor.swift     — delegates to ScreenFrameDifferencer, publishes ScreenChangeEvent
    ScreenFrameDifferencer.swift         — ScreenFrameDifferencer protocol + VNScreenFrameDifferencer production impl

Banti/Banti/Core/Events/
    ScreenChangeEvent.swift              — new event type
```

**Modified files:**

```
Banti/Banti/Modules/Perception/Screen/ScreenDescriptionActor.swift
    — subscribe to ScreenChangeEvent, remove time-throttle, add changeDistance to output

Banti/Banti/Core/Events/ScreenDescriptionEvent.swift
    — add changeDistance: Float? field and update memberwise init

Banti/Banti/BantiApp.swift
    — wire ScreenChangeDetectionActor into pipeline

Banti/Banti/Core/BantiModule.swift
    — add: static let screenChangeDetection = Capability("screen-change-detection")

Banti/Banti/Core/Environment.swift
    — add: static let screenChangeThreshold = "SCREEN_CHANGE_THRESHOLD"
```

**New test helper:**

```
BantiTests/.../MockScreenFrameDifferencer.swift
    — mirrors MockFrameDifferencer; returns user-controlled Float? values
```

---

## 6. Configuration Keys

| Key | Default | Description |
|---|---|---|
| `SCREEN_CHANGE_THRESHOLD` | `0.05` | Minimum `VNFeaturePrintObservation` distance to trigger a description; lower = more sensitive |
| `SCREEN_DESCRIPTION_INTERVAL_S` | — | **Deprecated.** Now ignored. If present, actor logs a one-time startup warning and continues. Key may be removed from `.env` at any time. |

---

## 7. App Wiring (BantiApp.swift)

```swift
let screenCapture   = ScreenCaptureActor(eventHub: eventHub, config: config)
let screenChange    = ScreenChangeDetectionActor(eventHub: eventHub, config: config)
let screenDesc      = ScreenDescriptionActor(eventHub: eventHub, config: config)
let activeApp       = ActiveAppActor(eventHub: eventHub)

// Registration order is LOAD-BEARING for initial startup:
// Actors are started in registration order. ScreenDescriptionActor must be
// started (and therefore subscribed to ScreenChangeEvent) before
// ScreenChangeDetectionActor starts publishing. Likewise, ScreenChangeDetectionActor
// must be subscribed to ScreenFrameEvent before ScreenCaptureActor starts.
// DO NOT reorder these registrations.
//
// The `dependencies:` parameter governs restart ordering only — if screenCapture
// crashes and restarts, the supervisor waits for screenChange to be healthy first
// before restarting it. The same applies to screenChange → screenDesc.
// EventHub subscriptions are established in start(), so registration order (not
// dependencies) is what ensures correct subscription setup on initial launch.
await supervisor.register(activeApp,     restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
await supervisor.register(screenDesc,    restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
await supervisor.register(screenChange,  restartPolicy: .onFailure(maxRetries: 3, backoff: 1),
                           dependencies: [screenDesc.id])
await supervisor.register(screenCapture, restartPolicy: .onFailure(maxRetries: 3, backoff: 2),
                           dependencies: [screenChange.id])
```

---

## 8. Error Handling

| Failure | Response |
|---|---|
| Vision framework error computing print | `.degraded`, logs error, skips frame, resumes on next |
| `computeDistance` throws | Same as above |
| ScreenDescriptionActor VLM error | Unchanged — `.degraded`, logs, resumes on next `ScreenChangeEvent` |

---

## 9. Testing Strategy

- **`ScreenChangeDetectionActorTests`**: inject `MockScreenFrameDifferencer` returning controlled `Float?` values; publish synthetic `ScreenFrameEvent`s; verify: (a) first frame always published with `changeDistance == nil`; (b) frames below threshold suppressed; (c) frames at or above threshold published with correct `changeDistance`; (d) Vision errors cause `.degraded` health and frame skip.
- **`ScreenDescriptionActorTests`**: update to publish `ScreenChangeEvent` (not `ScreenFrameEvent`); inject mock `VisionProvider`; verify `changeDistance` propagated into `ScreenDescriptionEvent`; verify back-to-back `ScreenChangeEvent`s both trigger VLM calls (no residual time-throttle).
- **Protocol conformance**: run existing `BantiModule` lifecycle suite against `ScreenChangeDetectionActor`.

---

## 10. Out of Scope

- Sharing `FrameDifferencer` / `VNFrameDifferencer` from `Camera/` — each pipeline owns its own Vision state; the screen module defines its own `ScreenFrameDifferencer` protocol and `VNScreenFrameDifferencer` implementation
- Hybrid mode (change + time floor) — pure change-gating only
- Configurable per-region thresholds
- Keeping `SCREEN_DESCRIPTION_INTERVAL_S` as a fallback floor (deprecated; startup warning logged if key is present)
