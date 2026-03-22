# Event Log UI Design

**Date:** 2026-03-21
**Status:** Approved

## Overview

Replace the transcript-only UI with a unified event log feed that shows all perception pipeline events in the app window. The window becomes a live monitor for the full pipeline rather than just speech output.

## Architecture

Introduce two new types and delete two existing ones:

- **`EventLogEntry`** — value type conforming to `Identifiable`: `id: UUID`, `timestampFormatted: String` (pre-formatted at entry creation time), `tag: String`, `text: String`
- **`EventLogViewModel`** — `@MainActor final class ObservableObject` with:
  - `init(eventHub: EventHubActor)`
  - `@Published var entries: [EventLogEntry]`
  - `@Published var isListening: Bool`
  - `@Published var errorMessage: String?`
  - `func startListening() async` — resets counters/timers, subscribes to all 10 types, sets `isListening = true`
  - `func stopListening() async` — unsubscribes all, clears subscription IDs, resets counters/timers, sets `isListening = false`
  - `func setError(_ message: String)` — sets `errorMessage`
  - `private var subscriptionIDs: [SubscriptionID]` (array, mirroring `EventLoggerActor`)
  - `private var audioFrameCount: UInt64` — throttle counter for audio frames
  - `private var lastCameraLog: Date` — time-based throttle for raw camera frames (1 per 60s)
  - `private var lastScreenLog: Date` — time-based throttle for raw screen frames (1 per 60s)
  - `EventHubActor` is an `actor`, so `subscribe`/`unsubscribe` require `await` (actor isolation crossing) — both `startListening()` and `stopListening()` must therefore be `async`
- Delete **`TranscriptViewModel`** and **`TranscriptView`**
- Add **`EventLogView`** — replaces `TranscriptView` as the root view in `BantiApp.body`

`BantiApp` changes:
- `@StateObject private var viewModel: TranscriptViewModel` → `@StateObject private var viewModel: EventLogViewModel`
- `bootstrap(...)` parameter `vm: TranscriptViewModel` → `vm: EventLogViewModel`
- `body` passes `EventLogViewModel` to `EventLogView` instead of `TranscriptViewModel` to `TranscriptView`
- `TranscriptProjectionActor` (`proj`) remains registered and running unchanged — `TranscriptSegmentEvent` is still published and consumed by `EventLogViewModel`
- `vm.startListening()` must be called **before** `sup.startAll()` in bootstrap, preserving the existing ordering

## Data Flow & Formatting

Each event is formatted into a single-line `text` string at entry creation time in `EventLogViewModel`. The **entire formatted string** is then truncated to 120 chars with `…` (truncation applies to the full string, not just the embedded text field).

The timestamp is formatted at entry creation time using a shared static `DateFormatter` with:
- `dateFormat = "HH:mm:ss.SSS"`
- `locale = Locale(identifier: "en_US_POSIX")`
- `timeZone = TimeZone.current`

| Event type | Tag | Format | Throttle |
|---|---|---|---|
| `AudioFrameEvent` | `[AUDIO]` | `frame=<seq> bytes=<n>` | Every 100th frame |
| `CameraFrameEvent` | `[CAMERA]` | `frame=<seq> size=<w>x<h>` | At most once per 60s |
| `RawTranscriptEvent` | `[RAW]` | `<speaker> \| conf=<0.00> \| <text>` — speaker is `"Speaker <n>"` when `speakerIndex` is set, `"unknown"` when nil; confidence to 2 d.p. | None |
| `TranscriptSegmentEvent` | `[SEGMENT]` | `<speakerLabel> \| <final\|interim> \| <text>` — use `event.speakerLabel` directly | None |
| `SceneDescriptionEvent` | `[SCENE]` | `latency=<n>ms \| <text>` | None |
| `ModuleStatusEvent` | `[MODULE]` | `<moduleID.rawValue>: <oldStatus> → <newStatus>` — arrow is U+2192 `→` | None |
| `ScreenFrameEvent` | `[SCRFRM]` | `frame=<seq> size=<w>x<h>` | At most once per 60s |
| `ScreenDescriptionEvent` | `[SCREEN]` | `latency=<n>ms \| <text>` | None |
| `ActiveAppEvent` | `[APP]` | `<prevApp> → <appName> (<bundleID>)` — `<prevApp> → ` omitted on first event | None |
| `AXFocusEvent` | `[AX]` | `<changeKind> \| <appName> \| <elementRole> [· <title>] [\| selected: '<text>']` | None |

**Audio throttling:** On every `AudioFrameEvent` received, `audioFrameCount` is incremented **unconditionally first** (mirroring `EventLoggerActor`), then the guard `audioFrameCount == 1 || audioFrameCount % 100 == 0` is checked — if it fails the handler returns without creating an entry. Counter is reset to `0` at the start of `startListening()` (defensive) and again in `stopListening()`.

**Camera/screen frame throttling:** Raw `CameraFrameEvent` and `ScreenFrameEvent` are shown at most once every 60 seconds in the UI. This prevents high-frequency frame events from flooding the log while still providing an occasional status indicator. `lastCameraLog` and `lastScreenLog` track the last log time and are reset on `startListening()`/`stopListening()`.

**Rolling buffer:** capped at 500 entries. When a new entry would exceed 500, `entries.removeFirst()` before appending.

**Text truncation threshold:** 120 characters on the full formatted string.

## UI

`EventLogView` structure:
- **Header bar**: red dot (`.red` when `isListening`, `.gray` otherwise) + "Listening…" / "Stopped" label, spacer, `"\(viewModel.entries.count) events"` count label
- **Error banner** (unchanged): yellow triangle + message when `errorMessage` is set
- **Divider**
- **Scrolling feed**: `LazyVStack` of rows inside a `ScrollViewReader`; auto-scrolls with animation to the last entry's `id` on `.onChange(of: viewModel.entries.last?.id)`. Always tracks the tail — no manual scroll suppression.
- **Frame**: `.frame(minWidth: 500, minHeight: 400)` — same as existing `TranscriptView`

Each row:
```
[TAG]   <text>
        <timestampFormatted>
```

Tag rendered in a fixed-width monospace label, color-coded by type:
- `[AUDIO]` → `.secondary`
- `[CAMERA]` → `.blue`
- `[RAW]` → `.orange`
- `[SEGMENT]` → `.green`
- `[SCENE]` → `.purple`
- `[MODULE]` → `.cyan`
- `[SCREEN]` → `.indigo`
- `[SCRFRM]` → `.teal`
- `[APP]` → `.mint`
- `[AX]` → `.pink`

## Error Handling

`EventLogViewModel` exposes `errorMessage: String?`. `BantiApp.bootstrap` calls `vm.setError(_:)` on pipeline failure, shown as the existing yellow-triangle banner.

## Testing

- `BantiTests/TranscriptProjectionActorTests.swift` — do **not** delete or modify; it tests the actor only.
- Delete any snapshot/view tests for `TranscriptView` if present.

Add **`EventLogViewModelTests`** covering:
1. Entry appended for each of the 6 event types
2. Audio throttling: only frame 1 and multiples of 100 produce entries
3. Audio counter resets on `stopListening()` — next `startListening()` logs frame 1 again
4. Audio counter resets defensively at start of `startListening()` — calling `startListening()` without a prior `stopListening()` still logs frame 1
5. Text truncated at 120 chars with `…` (full formatted string, not just the embedded text)
6. Rolling buffer capped at 500: entry 501 drops entry 1

## Files Changed

| Action | File |
|---|---|
| Add | `Banti/Banti/UI/EventLogEntry.swift` |
| Add | `Banti/Banti/UI/EventLogViewModel.swift` |
| Add | `Banti/Banti/UI/EventLogView.swift` |
| Delete | `Banti/Banti/UI/TranscriptViewModel.swift` |
| Delete | `Banti/Banti/UI/TranscriptView.swift` |
| Modify | `Banti/Banti/BantiApp.swift` |
| Add | `Banti/BantiTests/EventLogViewModelTests.swift` |
| Modify | `Banti/Banti.xcodeproj/project.pbxproj` — add all new `.swift` files to the Banti target; remove deleted files from the target |
