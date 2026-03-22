# Accessibility Perception Module Design

**Date:** 2026-03-21
**Status:** Draft
**Module:** Perception — AX Focus Observation
**Target:** macOS 14+ (Sonoma), Swift 5.9+, Xcode project (`.xcodeproj`)

---

## 1. Goal

Add an Accessibility perception pipeline to Banti. Unlike the camera and screen pipelines (which require VLM inference to extract meaning from images), the macOS Accessibility API (`AXUIElement`) exposes exact structured data: which app is focused, which UI element the user is editing, and what text is currently selected.

This gives Brain a zero-latency, zero-inference-cost signal for the most actionable context: **exactly what the user has their hands on right now**.

One actor is introduced in V1:

- `AXFocusActor` — uses `AXObserver` to watch for focus and selection changes across all apps, publishes `AXFocusEvent` whenever the focused element or selected text changes.

The design is extensible: future actors (browser URL tracking, terminal command observation, form field scanning) subscribe independently using the same AX APIs without touching `AXFocusActor`.

---

## 2. Architecture

### 2.1 New Modules (BantiModule conformers)

| Actor | Role |
|---|---|
| `AXFocusActor` | Observes AXUIElement focus + selection changes system-wide, publishes `AXFocusEvent` |

### 2.2 Pipeline

```
AXObserver (system accessibility callbacks)
    │ AXUIElementCopyAttributeValue on kAXFocusedUIElementAttribute change
    │ AXUIElementCopyAttributeValue on kAXSelectedTextAttribute change
    ▼
AXFocusActor               → debounces rapid focus changes (50ms window)
                           → publishes AXFocusEvent (app, role, title, selectedText, windowTitle)
    │ (EventHub)
    ▼
BrainActor                 → appends to context: [HH:mm:ss] (focus) "Xcode · AXTextArea · main.swift · selected: 'func foo()'"
```

`AXFocusActor` also subscribes to `ActiveAppEvent` (from the Screen pipeline) to efficiently re-register the `AXObserver` when the frontmost app changes, rather than polling.

---

## 3. Component Interfaces

### 3.1 AXFocusActor

```swift
actor AXFocusActor: BantiModule {
    nonisolated let id = ModuleID("ax-focus")
    nonisolated let capabilities: Set<Capability> = [.axObservation]

    init(eventHub: EventHubActor, config: ConfigActor)
    func start() async throws   // checks AX permission, installs observer for frontmost app
    func stop() async            // removes AXObserver, unsubscribes from EventHub
    func health() async -> ModuleHealth
}
```

---

## 4. AXObserver Threading Model

AXObserver callbacks run on the **main run loop** (they require `CFRunLoopAddSource`). This is a hard platform constraint — AX callbacks cannot be moved to a different thread.

**Strategy:** The AX callback is a plain C function (required by `AXObserverCreate`). It captures a reference to a `Sendable` bridge object (`AXEventBridge`) that holds a reference to the actor. On each callback, the bridge schedules an `async Task` to call a method on `AXFocusActor`. The actor then reads element attributes (also from that `Task`), debounces, and publishes.

```
Main RunLoop (AX callback thread)
    → AXEventBridge.notify()
        → Task { await axFocusActor.handleFocusChange(pid:) }
            → reads AXUIElement attributes
            → debounces
            → publishes AXFocusEvent via EventHub
```

**Why not `@MainActor`?** `AXFocusActor` must remain a regular `actor` (not `@MainActor`) so that attribute reads — which can involve IPC to the target app — don't block the main thread. The AX callback itself is minimal (just schedules the Task). All attribute reading happens off the main thread inside the actor.

---

## 5. AX Observation Strategy

### 5.1 Per-App Observer Registration

AXObserver is scoped to a single process (pid). `AXFocusActor` maintains one active observer targeting the frontmost application. When `ActiveAppEvent` fires, the actor:

1. Destroys the old `AXObserver` (removes from run loop, releases).
2. Creates a new `AXObserver` for the new app's pid.
3. Adds notifications: `kAXFocusedUIElementChangedNotification`, `kAXSelectedTextChangedNotification`, `kAXValueChangedNotification`.
4. Immediately reads the current focused element to publish an initial `AXFocusEvent` for the new app.

If `ActiveAppEvent` is not yet available (e.g. Screen pipeline not installed), `AXFocusActor` independently observes `NSWorkspace.didActivateApplicationNotification` as a fallback.

### 5.2 Notifications Observed

| AX Notification | Trigger | Action |
|---|---|---|
| `kAXFocusedUIElementChangedNotification` | User clicks a different field | Read new element's role, title, value |
| `kAXSelectedTextChangedNotification` | User selects/deselects text | Read `kAXSelectedTextAttribute` |
| `kAXValueChangedNotification` | Text field content changes | Read selected text (for cut/paste detection) |

### 5.3 Attribute Extraction

On each notification, `AXFocusActor` reads the following from the focused element:

| AX Attribute | Maps to |
|---|---|
| `kAXRoleAttribute` | `AXFocusEvent.elementRole` (e.g. "AXTextArea", "AXTextField", "AXWebArea") |
| `kAXTitleAttribute` or `kAXDescriptionAttribute` | `AXFocusEvent.elementTitle` |
| `kAXSelectedTextAttribute` | `AXFocusEvent.selectedText` (nil if nothing selected) |
| `kAXWindowAttribute` → `kAXTitleAttribute` | `AXFocusEvent.windowTitle` |

The app name and bundleID are taken from the pid (via `NSRunningApplication(processIdentifier:)`).

### 5.4 Debouncing

Typing rapidly triggers `kAXValueChangedNotification` on every keystroke. A 50ms debounce is applied: the actor cancels any pending publish Task and reschedules. This ensures Brain receives at most ~20 AX events/second even in rapid-typing scenarios.

Selected text changes are **not** debounced — they are published immediately because selection is deliberate user intent.

---

## 6. Event Contracts

### 6.1 AXFocusEvent

```swift
struct AXFocusEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID              // "ax-focus"

    // App context
    let appName: String                     // e.g. "Xcode"
    let bundleIdentifier: String            // e.g. "com.apple.dt.Xcode"

    // Element context
    let elementRole: String                 // AX role string, e.g. "AXTextArea"
    let elementTitle: String?               // label or title of element, nil if unavailable
    let windowTitle: String?                // title of containing window

    // Selection (nil if nothing selected)
    let selectedText: String?
    let selectedTextLength: Int             // 0 if no selection; avoids sending huge pastes in full

    // Change kind — helps Brain decide how much attention to pay
    let changeKind: AXChangeKind
}

enum AXChangeKind: String, Sendable {
    case focusChanged       // user moved focus to a different element
    case selectionChanged   // user selected/deselected text in the current element
    case valueChanged       // element value changed (typing)
    case appSwitched        // first event after app switch (synthetic, always published)
}
```

**Privacy note on `selectedText`:** Selected text is included in full up to `AX_SELECTED_TEXT_MAX_CHARS` (default 2000). Above that limit, only `selectedTextLength` is populated and `selectedText` is nil. This prevents accidentally sending entire document contents if the user selects all.

---

## 7. New Files

```
Banti/Banti/Modules/Perception/Accessibility/
    AXFocusActor.swift           — AXObserver management, publishes AXFocusEvent
    AXEventBridge.swift          — non-isolated C-callback bridge; schedules Tasks into AXFocusActor

Banti/Banti/Core/Events/
    AXFocusEvent.swift           — AXFocusEvent + AXChangeKind
```

New `Capability` constant added to `BantiModule.swift`:
```swift
static let axObservation = Capability("ax-observation")
```

---

## 8. Configuration Keys

Added to `Environment.swift`:

| Key | Default | Description |
|---|---|---|
| `AX_DEBOUNCE_MS` | `50` | Debounce window for value-changed events |
| `AX_SELECTED_TEXT_MAX_CHARS` | `2000` | Max selected text length before truncation |

---

## 9. Entitlements & Permissions

No entitlement key is needed — AX access is controlled by the user in **System Settings → Privacy & Security → Accessibility**. The app must be listed there.

The app requests access at launch using:

```swift
AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt: true] as CFDictionary
)
```

If not trusted, `AXFocusActor.start()` throws and health becomes `.failed`. The supervisor does not retry (permission won't change without user action). The UI should surface a link to System Settings.

```xml
<!-- Info.plist -->
<key>NSAccessibilityUsageDescription</key>
<string>Banti reads your focused UI element and selected text to provide context-aware assistance.</string>
```

---

## 10. Error Handling

| Failure | Response |
|---|---|
| AX permission not granted | `.failed`, no retry, surface permission prompt in UI |
| Target app exits during observation | AX callback stops; `ActiveAppEvent` fires immediately with new app; observer re-registered |
| AXObserver creation fails (sandboxed target app) | Logs warning, skips that app, `health()` stays `.healthy` (partial degradation expected for sandboxed apps) |
| AX attribute read returns `kAXErrorNoValue` | Field is empty or unsupported; publish event with `nil` fields, no error |
| AX attribute read returns other error | Log + skip publish; health stays `.healthy` unless error rate >20% in 10s → `.degraded` |

**Sandboxed apps:** Many Mac App Store apps restrict AX access. `AXFocusActor` will successfully observe first-party Apple apps (Safari, Notes, Mail, Terminal) and developer tools (Xcode, VS Code). For fully sandboxed apps, observation silently fails — the actor stays healthy and Brain simply has no AX context for that app.

---

## 11. Startup Registration (BantiApp.swift additions)

```swift
let axFocus = AXFocusActor(eventHub: eventHub, config: config)

await supervisor.register(axFocus, restartPolicy: .onFailure(maxRetries: 2, backoff: 2))
```

`AXFocusActor` has no module dependencies (it can subscribe to `ActiveAppEvent` on its own). It can start alongside the other perception modules.

---

## 12. Testing Strategy

- **`AXFocusActorTests`**: mock `AXEventBridge` to inject synthetic notifications; verify correct `AXFocusEvent` fields and `changeKind` for each notification type.
- **Debounce test**: fire 10 rapid `valueChanged` notifications within 50ms; verify only 1 `AXFocusEvent` published.
- **Selection test**: fire `selectedTextChanged`; verify event published immediately (no debounce delay).
- **App switch test**: inject `ActiveAppEvent`; verify observer re-registered and synthetic `appSwitched` event published.
- **Truncation test**: inject selected text of 3000 chars; verify `selectedText` is nil and `selectedTextLength` is 3000.
- **Protocol conformance tests**: run existing `BantiModule` lifecycle suite.

---

## 13. Dependencies

- **ApplicationServices / AXUIElement** (system framework) — core AX observation
- **AppKit / NSRunningApplication** (system framework) — pid → app name/bundle ID resolution
- **EventHub** (existing) — subscriptions to `ActiveAppEvent`; publishing `AXFocusEvent`
- **No third-party dependencies**

---

## 14. Out of Scope

- Browser URL extraction (needs AX path to address bar element — separate actor)
- Terminal command history (needs AX value reads on Terminal.app — separate actor)
- Cursor / caret position within document
- Undo history observation
- AX for Banti's own UI (self-observation not useful)
