# Event Log UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the transcript-only SwiftUI window with a unified event log feed showing all 6 perception pipeline event types in real time.

**Architecture:** Introduce `EventLogEntry` (value type) and `EventLogViewModel` (`@MainActor ObservableObject`) that subscribes to all 6 event types on `EventHubActor`. Replace `TranscriptView`/`TranscriptViewModel` with `EventLogView`/`EventLogViewModel` in `BantiApp`. Tests drive each component before implementation.

**Tech Stack:** Swift 6, SwiftUI, XCTest, `EventHubActor` (actor-based pub/sub), Xcode project file management

---

## File Map

| Action | File | Responsibility |
|---|---|---|
| Create | `Banti/Banti/UI/EventLogEntry.swift` | Value type: one display row |
| Create | `Banti/Banti/UI/EventLogViewModel.swift` | Subscribe to hub, format events, rolling buffer |
| Create | `Banti/Banti/UI/EventLogView.swift` | SwiftUI view: header + feed |
| Create | `Banti/BantiTests/EventLogViewModelTests.swift` | Unit tests for the VM |
| Delete | `Banti/Banti/UI/TranscriptViewModel.swift` | Replaced by EventLogViewModel |
| Delete | `Banti/Banti/UI/TranscriptView.swift` | Replaced by EventLogView |
| Modify | `Banti/Banti/BantiApp.swift` | Wire EventLogViewModel, pass to EventLogView |
| Modify | `Banti/Banti.xcodeproj/project.pbxproj` | Register new files, remove deleted files |

---

## Task 1: `EventLogEntry` value type

**Files:**
- Create: `Banti/Banti/UI/EventLogEntry.swift`

- [ ] **Step 1: Create the file**

```swift
// Banti/Banti/UI/EventLogEntry.swift
import Foundation

struct EventLogEntry: Identifiable {
    let id: UUID
    let tag: String
    let text: String
    let timestampFormatted: String
}
```

- [ ] **Step 2: Register in Xcode**

In Xcode: File → Add Files, add `EventLogEntry.swift` to the **Banti** app target (not test target). Confirm it appears in `project.pbxproj` under the Banti target's source build phase.

- [ ] **Step 3: Build to confirm it compiles**

Build the Banti scheme (⌘B). Expected: build succeeds, no errors.

- [ ] **Step 4: Commit**

```bash
git add Banti/Banti/UI/EventLogEntry.swift Banti/Banti.xcodeproj/project.pbxproj
git commit -m "feat: add EventLogEntry value type"
```

---

## Task 2: `EventLogViewModelTests` — skeleton + first 2 tests (entry appended per event type)

**Files:**
- Create: `Banti/BantiTests/EventLogViewModelTests.swift`

This task writes the failing tests for event-type coverage. The VM doesn't exist yet — tests will fail to compile until Task 3. That's intentional: write the tests first, then implement.

- [ ] **Step 1: Create the test file with imports and helpers**

```swift
// Banti/BantiTests/EventLogViewModelTests.swift
import XCTest
@testable import Banti

@MainActor
final class EventLogViewModelTests: XCTestCase {

    // MARK: - Helpers

    func makeAudioFrame(seq: UInt64 = 1) -> AudioFrameEvent {
        AudioFrameEvent(audioData: Data(repeating: 0, count: 64), sequenceNumber: seq)
    }

    func makeCameraFrame(seq: UInt64 = 1) -> CameraFrameEvent {
        CameraFrameEvent(jpeg: Data(repeating: 0, count: 100), sequenceNumber: seq,
                         frameWidth: 640, frameHeight: 480)
    }

    func makeRawTranscript(speaker: Int? = 0, text: String = "hello") -> RawTranscriptEvent {
        RawTranscriptEvent(text: text, speakerIndex: speaker, confidence: 0.91,
                           isFinal: true, audioStartTime: 0, audioEndTime: 1)
    }

    func makeSegment(speaker: String = "Speaker 1", text: String = "hello",
                     isFinal: Bool = true) -> TranscriptSegmentEvent {
        TranscriptSegmentEvent(speakerLabel: speaker, text: text,
                               startTime: 0, endTime: 1, isFinal: isFinal)
    }

    func makeScene(text: String = "A desk") -> SceneDescriptionEvent {
        let now = Date()
        return SceneDescriptionEvent(text: text,
                                     captureTime: now.addingTimeInterval(-1),
                                     responseTime: now)
    }

    func makeModuleStatus() -> ModuleStatusEvent {
        ModuleStatusEvent(moduleID: ModuleID("mic"), oldStatus: "starting", newStatus: "running")
    }
}
```

- [ ] **Step 2: Add test — entry appended for each of the 6 event types**

```swift
    // MARK: - Entry appended per event type

    func testAudioFrameCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeAudioFrame(seq: 1))
        // Allow the async subscriber to run
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[AUDIO]")
    }

    func testCameraFrameCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeCameraFrame())
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[CAMERA]")
    }

    func testRawTranscriptCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeRawTranscript())
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[RAW]")
    }

    func testTranscriptSegmentCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeSegment())
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[SEGMENT]")
    }

    func testSceneDescriptionCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeScene())
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[SCENE]")
    }

    func testModuleStatusCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeModuleStatus())
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[MODULE]")
    }
```

- [ ] **Step 3: Register test file in Xcode**

Add `EventLogViewModelTests.swift` to the **BantiTests** target in Xcode.

- [ ] **Step 4: Build — expect compile error** (EventLogViewModel doesn't exist yet)

Build BantiTests (⌘B). Expected: compile error "cannot find type EventLogViewModel". This is correct — proceed to Task 3.

---

## Task 3: `EventLogViewModel` — core subscribe/unsubscribe + event type formatting

**Files:**
- Create: `Banti/Banti/UI/EventLogViewModel.swift`

- [ ] **Step 1: Create the VM with the DateFormatter and empty formatting stubs**

```swift
// Banti/Banti/UI/EventLogViewModel.swift
import Foundation
import SwiftUI

@MainActor
final class EventLogViewModel: ObservableObject {
    @Published var entries: [EventLogEntry] = []
    @Published var isListening = false
    @Published var errorMessage: String?

    private let eventHub: EventHubActor
    private var subscriptionIDs: [SubscriptionID] = []
    private var audioFrameCount: UInt64 = 0

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    init(eventHub: EventHubActor) {
        self.eventHub = eventHub
    }

    // MARK: - Lifecycle

    func startListening() async {
        audioFrameCount = 0
        subscriptionIDs.append(await eventHub.subscribe(AudioFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleAudio(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(CameraFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[CAMERA]", text: self.format(event))
        })
        subscriptionIDs.append(await eventHub.subscribe(RawTranscriptEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[RAW]", text: self.format(event))
        })
        subscriptionIDs.append(await eventHub.subscribe(TranscriptSegmentEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[SEGMENT]", text: self.format(event))
        })
        subscriptionIDs.append(await eventHub.subscribe(SceneDescriptionEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[SCENE]", text: self.format(event))
        })
        subscriptionIDs.append(await eventHub.subscribe(ModuleStatusEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[MODULE]", text: self.format(event))
        })
        isListening = true
    }

    func stopListening() async {
        for id in subscriptionIDs {
            await eventHub.unsubscribe(id)
        }
        subscriptionIDs.removeAll()
        audioFrameCount = 0
        isListening = false
    }

    func setError(_ message: String) {
        errorMessage = message
    }

    // MARK: - Private

    private func handleAudio(_ event: AudioFrameEvent) {
        audioFrameCount += 1
        guard audioFrameCount == 1 || audioFrameCount % 100 == 0 else { return }
        append(tag: "[AUDIO]", text: format(event))
    }

    private func append(tag: String, text: String) {
        let truncated = text.count > 120 ? String(text.prefix(120)) + "…" : text
        let entry = EventLogEntry(
            id: UUID(),
            tag: tag,
            text: truncated,
            timestampFormatted: Self.timestampFormatter.string(from: Date())
        )
        if entries.count >= 500 { entries.removeFirst() }
        entries.append(entry)
    }

    // MARK: - Formatters

    private func format(_ e: AudioFrameEvent) -> String {
        "frame=\(e.sequenceNumber) bytes=\(e.audioData.count)"
    }

    private func format(_ e: CameraFrameEvent) -> String {
        "frame=\(e.sequenceNumber) bytes=\(e.jpeg.count) size=\(e.frameWidth)x\(e.frameHeight)"
    }

    private func format(_ e: RawTranscriptEvent) -> String {
        let speaker = e.speakerIndex.map { "Speaker \($0)" } ?? "unknown"
        return "\(speaker) | conf=\(String(format: "%.2f", e.confidence)) | \(e.text)"
    }

    private func format(_ e: TranscriptSegmentEvent) -> String {
        "\(e.speakerLabel) | \(e.isFinal ? "final" : "interim") | \(e.text)"
    }

    private func format(_ e: SceneDescriptionEvent) -> String {
        let ms = Int(e.responseTime.timeIntervalSince(e.captureTime) * 1000)
        return "latency=\(ms)ms | \(e.text)"
    }

    private func format(_ e: ModuleStatusEvent) -> String {
        "\(e.moduleID.rawValue): \(e.oldStatus) \u{2192} \(e.newStatus)"
    }
}
```

- [ ] **Step 2: Register in Xcode**

Add `EventLogViewModel.swift` to the **Banti** app target in Xcode.

- [ ] **Step 3: Run the 6 event-type tests**

In Xcode: run `EventLogViewModelTests` (⌘U or filter to this class). Expected: all 6 `test*CreatesEntry` tests **pass**.

- [ ] **Step 4: Commit**

```bash
git add Banti/Banti/UI/EventLogViewModel.swift \
        Banti/BantiTests/EventLogViewModelTests.swift \
        Banti/Banti.xcodeproj/project.pbxproj
git commit -m "feat: add EventLogViewModel with 6-type subscription and formatters"
```

---

## Task 4: Audio throttling tests + verify

- [ ] **Step 1: Add throttling tests to `EventLogViewModelTests`**

```swift
    // MARK: - Audio throttling

    func testAudioOnlyLogsFrame1AndMultiplesOf100() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        // Publish 200 frames
        for seq in UInt64(1)...200 {
            await hub.publish(makeAudioFrame(seq: seq))
        }
        await Task.yield()

        // Expected: frame 1, frame 100, frame 200 → 3 entries
        XCTAssertEqual(vm.entries.count, 3)
        XCTAssertTrue(vm.entries.allSatisfy { $0.tag == "[AUDIO]" })
    }

    func testAudioCounterResetsOnStop() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        // Publish frame 1 (logged), then frames 2–50 (not logged)
        for seq in UInt64(1)...50 {
            await hub.publish(makeAudioFrame(seq: seq))
        }
        await Task.yield()
        XCTAssertEqual(vm.entries.count, 1) // only frame 1

        await vm.stopListening()

        // After stop, counter should be 0
        // Start again — frame 1 should be logged again
        await vm.startListening()
        await hub.publish(makeAudioFrame(seq: 51))
        await Task.yield()

        // 1 entry from before + 1 new entry = 2
        XCTAssertEqual(vm.entries.count, 2)
        XCTAssertEqual(vm.entries[1].tag, "[AUDIO]")
    }

    func testAudioCounterResetsDefensivelyOnStart() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)

        // First listen session: advance counter past 1, then call startListening()
        // AGAIN without stopListening() first. This tests the defensive reset in
        // startListening() itself — not the reset in stopListening().
        await vm.startListening()
        for seq in UInt64(1)...50 {
            await hub.publish(makeAudioFrame(seq: seq))
        }
        await Task.yield()
        let countAfterFirstSession = vm.entries.count // should be 1 (frame 1 only)

        // Call startListening() again WITHOUT stopListening() first.
        // The defensive reset in startListening() sets audioFrameCount = 0.
        await vm.startListening()
        await hub.publish(makeAudioFrame(seq: 99)) // first frame in new counter → logged
        await Task.yield()

        // Should have logged 1 more entry (the "first" frame in the reset counter)
        XCTAssertGreaterThan(vm.entries.count, countAfterFirstSession)
    }
```

- [ ] **Step 2: Run throttling tests**

Run `EventLogViewModelTests`. Expected: all 3 throttling tests **pass**.

- [ ] **Step 3: Commit**

```bash
git add Banti/BantiTests/EventLogViewModelTests.swift
git commit -m "test: verify audio throttling and counter reset behavior"
```

---

## Task 5: Truncation and rolling buffer tests + verify

- [ ] **Step 1: Add truncation and buffer tests**

```swift
    // MARK: - Truncation

    func testTextTruncatedAt120Chars() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        // Build a segment whose full formatted string exceeds 120 chars
        // Format: "Speaker 1 | final | <text>"
        // "Speaker 1 | final | " is 20 chars, so 101+ chars of text triggers truncation
        let longText = String(repeating: "a", count: 120)
        await hub.publish(makeSegment(text: longText))
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        let text = vm.entries[0].text
        XCTAssertTrue(text.hasSuffix("…"), "Expected truncation ellipsis, got: \(text)")
        // Swift String.count counts Unicode scalars; prefix(120) gives 120 chars + "…"
        XCTAssertLessThanOrEqual(text.count, 121) // 120 chars + "…"
    }

    func testShortTextIsNotTruncated() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeSegment(text: "short"))
        await Task.yield()

        XCTAssertFalse(vm.entries[0].text.hasSuffix("…"))
    }

    // MARK: - Rolling buffer

    func testRollingBufferCappedAt500() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        // Fill buffer with 500 scene events
        for i in 0..<500 {
            await hub.publish(makeScene(text: "scene \(i)"))
        }
        await Task.yield()
        XCTAssertEqual(vm.entries.count, 500)

        // Capture the second entry's text (will become first after overflow)
        let secondEntryText = vm.entries[1].text

        // Add one more — should drop the first entry
        await hub.publish(makeScene(text: "scene 500"))
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 500)
        // The old first entry is gone; old second is now first
        XCTAssertTrue(vm.entries[0].text.contains(secondEntryText.prefix(20)),
                      "Expected buffer to drop oldest entry")
        // The newest entry is last
        XCTAssertTrue(vm.entries.last?.text.contains("scene 500") == true)
    }
```

- [ ] **Step 2: Add `isListening` state transition tests**

```swift
    // MARK: - isListening state

    func testIsListeningInitiallyFalse() {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        XCTAssertFalse(vm.isListening)
    }

    func testIsListeningSetOnStartAndStop() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        XCTAssertFalse(vm.isListening)

        await vm.startListening()
        XCTAssertTrue(vm.isListening)

        await vm.stopListening()
        XCTAssertFalse(vm.isListening)
    }
```

- [ ] **Step 3: Run truncation, buffer, and isListening tests**

Run `EventLogViewModelTests`. Expected: all tests **pass**.

- [ ] **Step 4: Commit**

```bash
git add Banti/BantiTests/EventLogViewModelTests.swift
git commit -m "test: verify text truncation, rolling buffer cap, and isListening state"
```

---

## Task 6: `EventLogView`

**Files:**
- Create: `Banti/Banti/UI/EventLogView.swift`

- [ ] **Step 1: Create the view**

```swift
// Banti/Banti/UI/EventLogView.swift
import SwiftUI

struct EventLogView: View {
    @ObservedObject var viewModel: EventLogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.1))
            }
            Divider()
            feedList
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var headerBar: some View {
        HStack {
            Circle()
                .fill(viewModel.isListening ? Color.red : Color.gray)
                .frame(width: 10, height: 10)
            Text(viewModel.isListening ? "Listening…" : "Stopped")
                .font(.headline)
            Spacer()
            Text("\(viewModel.entries.count) events")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var feedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.entries) { entry in
                        entryRow(entry)
                            .id(entry.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.entries.count) { _, _ in
                if let last = viewModel.entries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: EventLogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.tag)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(color(for: entry.tag))
                .frame(width: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.body)
                Text(entry.timestampFormatted)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func color(for tag: String) -> Color {
        switch tag {
        case "[AUDIO]":   return .secondary
        case "[CAMERA]":  return .blue
        case "[RAW]":     return .orange
        case "[SEGMENT]": return .green
        case "[SCENE]":   return .purple
        case "[MODULE]":  return .cyan
        default:          return .primary
        }
    }
}
```

- [ ] **Step 2: Register in Xcode**

Add `EventLogView.swift` to the **Banti** app target.

- [ ] **Step 3: Build to confirm it compiles**

⌘B. Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Banti/Banti/UI/EventLogView.swift Banti/Banti.xcodeproj/project.pbxproj
git commit -m "feat: add EventLogView — unified perception event feed"
```

---

## Task 7: Wire into `BantiApp`, delete old files

**Files:**
- Modify: `Banti/Banti/BantiApp.swift`
- Delete: `Banti/Banti/UI/TranscriptViewModel.swift`
- Delete: `Banti/Banti/UI/TranscriptView.swift`

- [ ] **Step 1: Check for snapshot/view tests referencing TranscriptView**

```bash
grep -r "TranscriptView" Banti/BantiTests/
```

If any files are found, delete those test files (or remove the offending test cases). If nothing is found, proceed.

- [ ] **Step 2: Update `BantiApp.swift`**

Run a global replace across the file for all four substitutions:
```bash
grep -n "TranscriptViewModel\|TranscriptView" Banti/Banti/BantiApp.swift
```
Every hit must be updated. The complete resulting file should be:

```swift
import SwiftUI
import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }
}

@main
struct BantiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel: EventLogViewModel
    private let logger = Logger(subsystem: "com.banti.app", category: "Lifecycle")

    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let stateRegistry: StateRegistryActor
    private let supervisor: ModuleSupervisorActor
    private let eventLogger: EventLoggerActor
    private let micCapture: MicrophoneCaptureActor
    private let deepgram: DeepgramStreamingActor
    private let projection: TranscriptProjectionActor
    private let camera: CameraFrameActor
    private let sceneDesc: SceneDescriptionActor

    init() {
        let envPath = Self.resolveEnvPath()
        logger.notice("Resolved env path: \(envPath, privacy: .public)")

        let hub = EventHubActor()
        let cfg = ConfigActor(envFilePath: envPath)
        let reg = StateRegistryActor()
        let sup = ModuleSupervisorActor(eventHub: hub, stateRegistry: reg)
        let loggerActor = EventLoggerActor(eventHub: hub)
        let mic = MicrophoneCaptureActor(eventHub: hub)
        let dg = DeepgramStreamingActor(eventHub: hub, config: cfg, replayProvider: mic)
        let proj = TranscriptProjectionActor(eventHub: hub)
        let cameraActor = CameraFrameActor(eventHub: hub, config: cfg)
        let sceneDescActor = SceneDescriptionActor(eventHub: hub, config: cfg, replayProvider: cameraActor)

        self.eventHub = hub
        self.config = cfg
        self.stateRegistry = reg
        self.supervisor = sup
        self.eventLogger = loggerActor
        self.micCapture = mic
        self.deepgram = dg
        self.projection = proj
        self.camera = cameraActor
        self.sceneDesc = sceneDescActor

        let vm = EventLogViewModel(eventHub: hub)
        _viewModel = StateObject(wrappedValue: vm)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { try? await sup.restart(mic.id) }
        }

        Task {
            await Self.bootstrap(
                sup: sup, eventLogger: loggerActor, mic: mic, dg: dg, proj: proj,
                camera: cameraActor, sceneDesc: sceneDescActor, vm: vm
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            EventLogView(viewModel: viewModel)
        }
    }

    private static func bootstrap(
        sup: ModuleSupervisorActor,
        eventLogger: EventLoggerActor,
        mic: MicrophoneCaptureActor,
        dg: DeepgramStreamingActor,
        proj: TranscriptProjectionActor,
        camera: CameraFrameActor,
        sceneDesc: SceneDescriptionActor,
        vm: EventLogViewModel          // ← changed from TranscriptViewModel
    ) async {
        let logger = Logger(subsystem: "com.banti.app", category: "Lifecycle")
        logger.notice("bootstrap entered")

        await sup.register(eventLogger, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(proj, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(dg, restartPolicy: .onFailure(maxRetries: 5, backoff: 1))
        await sup.register(mic, restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [dg.id, proj.id])
        await sup.register(sceneDesc, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(camera, restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [sceneDesc.id])

        do {
            // vm.startListening() MUST come before sup.startAll() — ensures EventLogViewModel
            // is subscribed to all 6 event types before any module begins publishing.
            await vm.startListening()
            try await sup.startAll()
            logger.notice("bootstrap completed — pipeline running")
        } catch {
            logger.error("Pipeline failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run { vm.setError(error.localizedDescription) }
        }
    }

    private static func resolveEnvPath() -> String {
        let candidates: [String?] = [
            Bundle.main.path(forResource: ".env", ofType: nil),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".env").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/Code/banti/.env").path,
        ]
        for case let path? in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return candidates.compactMap({ $0 }).first ?? ".env"
    }
}
```

- [ ] **Step 3: Delete old files from disk**

```bash
rm Banti/Banti/UI/TranscriptViewModel.swift
rm Banti/Banti/UI/TranscriptView.swift
```

- [ ] **Step 4: Remove deleted files from Xcode project**

In Xcode: select `TranscriptViewModel.swift` and `TranscriptView.swift` in the project navigator → Delete → "Remove Reference". Confirm neither appears in `project.pbxproj` afterwards.

- [ ] **Step 5: Build and verify it compiles**

⌘B. Expected: clean build, no references to `TranscriptViewModel` or `TranscriptView` remaining.

- [ ] **Step 6: Verify `TranscriptProjectionActorTests` still passes**

```bash
grep -c "TranscriptProjectionActor" Banti/BantiTests/TranscriptProjectionActorTests.swift
```

Expected: non-zero output (file is untouched). Run just that test class (filter in Xcode or `xcodebuild test -only-testing:BantiTests/TranscriptProjectionActorTests`). Expected: all pass.

- [ ] **Step 7: Run all tests**

⌘U. Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Banti/Banti/BantiApp.swift \
        Banti/Banti.xcodeproj/project.pbxproj
git rm Banti/Banti/UI/TranscriptViewModel.swift \
       Banti/Banti/UI/TranscriptView.swift
git commit -m "feat: wire EventLogView into BantiApp, remove TranscriptView/ViewModel"
```

---

## Task 8: Smoke test the running app

- [ ] **Step 1: Run the app**

Verify `dev.sh` exists first:
```bash
ls dev.sh
```
If it exists, run it. Otherwise launch via Xcode (⌘R):
```bash
./dev.sh
```

Expected:
- Window opens with "Listening…" in the header
- `[MODULE]` entries appear as each module starts (supervisor publishes `ModuleStatusEvent`)
- `[AUDIO]` entry appears for the first audio frame, then every 100th
- `[SEGMENT]` entries appear as speech is transcribed
- `[SCENE]` entries appear as the camera pipeline produces descriptions
- Event count in header increments

- [ ] **Step 2: Verify rolling buffer**

Speak continuously for ~2 minutes. Confirm the event count stays at or below 500.

- [ ] **Step 3: Final commit if any tweaks needed**

```bash
git add -p  # stage only intentional changes
git commit -m "fix: <description of any smoke-test fixes>"
```
