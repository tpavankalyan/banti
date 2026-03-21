# Event Log UI Design

**Date:** 2026-03-21
**Status:** Approved

## Overview

Replace the transcript-only UI with a unified event log feed that shows all perception pipeline events in the app window. The window becomes a live monitor for the full pipeline rather than just speech output.

## Architecture

Introduce two new types and delete two existing ones:

- **`EventLogEntry`** — value type: `id: UUID`, `timestamp: Date`, `tag: String`, `text: String`
- **`EventLogViewModel`** — `@MainActor ObservableObject` subscribing to `EventHubActor` for all 6 event types; formats entries, appends to a rolling buffer
- Delete **`TranscriptViewModel`** and **`TranscriptView`**
- Add **`EventLogView`** — replaces `TranscriptView` as the root view in `BantiApp.body`

`BantiApp` passes `eventHub` to `EventLogViewModel` instead of `TranscriptViewModel`. No other wiring changes.

## Data Flow & Formatting

Each event is formatted into a single-line string, truncated at 120 chars with `…`, and tagged:

| Event type | Tag | Format |
|---|---|---|
| `AudioFrameEvent` | `[AUDIO]` | `frame=<seq> bytes=<n>` |
| `CameraFrameEvent` | `[CAMERA]` | `frame=<seq> bytes=<n> size=<w>x<h>` |
| `RawTranscriptEvent` | `[RAW]` | `<speaker> \| conf=<x> \| <text>` |
| `TranscriptSegmentEvent` | `[SEGMENT]` | `<speaker> \| <final\|interim> \| <text>` |
| `SceneDescriptionEvent` | `[SCENE]` | `latency=<n>ms \| <text>` |
| `ModuleStatusEvent` | `[MODULE]` | `<moduleID>: <old> → <new>` |

**Audio throttling:** only frame #1 and every 100th frame are logged — same policy as `EventLoggerActor` — to prevent audio spam drowning other events.

**Rolling buffer:** capped at 500 entries. Oldest entries are dropped when the cap is reached.

**Text truncation threshold:** 120 characters.

## UI

`EventLogView` structure:
- **Header bar** (same as current): red dot + "Listening…" / "Stopped" label, spacer, event count (total entries in buffer)
- **Error banner** (unchanged): yellow triangle + message when `errorMessage` is set
- **Divider**
- **Scrolling feed**: `LazyVStack` of rows, auto-scrolls to bottom on new entry

Each row:
```
[TAG]   <text truncated at 120 chars>
        <timestamp HH:mm:ss.SSS>
```

Tag rendered in a fixed-width monospace label, color-coded by type:
- `[AUDIO]` → gray
- `[CAMERA]` → blue
- `[RAW]` → orange
- `[SEGMENT]` → green
- `[SCENE]` → purple
- `[MODULE]` → yellow

## Error Handling

`EventLogViewModel` exposes `errorMessage: String?` — same interface as `TranscriptViewModel`. `BantiApp.bootstrap` calls `vm.setError(_:)` on pipeline failure, surfaced as the existing banner.

Subscription lifecycle: `startListening()` subscribes to all 6 event types; `stopListening()` unsubscribes all and resets the audio frame counter.

## Testing

Delete:
- `TranscriptProjectionActorTests` references to `TranscriptViewModel` (those tests cover the actor, not the VM — keep the actor tests)
- Any snapshot/view tests for `TranscriptView`

Add **`EventLogViewModelTests`** covering:
1. Entry appended for each of the 6 event types
2. Audio throttling: only frame 1 and multiples of 100 produce entries
3. Text truncated at 120 chars with `…`
4. Rolling buffer capped at 500: entry 501 drops entry 1

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
