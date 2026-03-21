# Perception-Only Cleanup + EventLoggerActor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Brain and Action modules, delete their associated events and tests, clean up dead config keys, and add a passive `EventLoggerActor` that logs all perception events to Console.app.

**Architecture:** Delete 10 Swift files (Brain module, Action module, their events, their tests), strip `BantiApp.swift` of the wiring, and add a single new `EventLoggerActor` in `Core/` that subscribes to all 6 event types and logs to `os.Logger`. The logger is registered first in the bootstrap so it never misses an event.

**Tech Stack:** Swift 6 actors, `os.Logger`, `BantiModule` protocol

---

### Task 1: Delete non-perception Swift files from disk

**Files:**
- Delete (git-tracked): `Banti/Banti/Modules/Brain/BrainActor.swift`
- Delete (git-tracked): `Banti/Banti/Modules/Action/SpeechActor.swift`
- Delete (git-tracked): `Banti/Banti/Core/Events/BrainResponseEvent.swift`
- Delete (git-tracked): `Banti/Banti/Core/Events/BrainThoughtEvent.swift`
- Delete (git-tracked): `Banti/Banti/Core/Events/SpeechPlaybackEvent.swift`
- Delete (git-tracked): `Banti/BantiTests/BrainActorTests.swift`
- Delete (git-tracked): `Banti/BantiTests/SpeechActorTests.swift`
- Delete (untracked): `Banti/Banti/Modules/Brain/LLMProvider.swift`
- Delete (untracked): `Banti/Banti/Modules/Brain/CerebrasProvider.swift`
- Delete (untracked): `Banti/Banti/Modules/Brain/ClaudeProvider.swift`

- [ ] **Step 1: Delete tracked files via git rm**

Run from `Banti/` (the Xcode project root):
```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti && \
git rm Banti/Modules/Brain/BrainActor.swift \
       Banti/Modules/Action/SpeechActor.swift \
       Banti/Core/Events/BrainResponseEvent.swift \
       Banti/Core/Events/BrainThoughtEvent.swift \
       Banti/Core/Events/SpeechPlaybackEvent.swift \
       BantiTests/BrainActorTests.swift \
       BantiTests/SpeechActorTests.swift
```
Expected: 7 lines like `rm 'Banti/Modules/Brain/BrainActor.swift'`

- [ ] **Step 2: Delete untracked files**

```bash
rm /Users/tpavankalyan/Downloads/Code/banti/Banti/Banti/Modules/Brain/LLMProvider.swift \
   /Users/tpavankalyan/Downloads/Code/banti/Banti/Banti/Modules/Brain/CerebrasProvider.swift \
   /Users/tpavankalyan/Downloads/Code/banti/Banti/Banti/Modules/Brain/ClaudeProvider.swift
```
Expected: no output (silent success)

- [ ] **Step 3: Remove the now-empty Brain/ and Action/ directories**

```bash
rmdir /Users/tpavankalyan/Downloads/Code/banti/Banti/Banti/Modules/Brain
rmdir /Users/tpavankalyan/Downloads/Code/banti/Banti/Banti/Modules/Action
```
Expected: no output

---

### Task 2: Remove dead references from Xcode project file

**Files:**
- Modify: `Banti/Banti.xcodeproj/project.pbxproj`

The pbxproj has one line per file reference and one line per build file entry. Removing all lines that mention a deleted filename is safe because filenames are unique across the project.

- [ ] **Step 1: Strip all pbxproj lines referencing deleted filenames**

```bash
PBXPROJ="/Users/tpavankalyan/Downloads/Code/banti/Banti/Banti.xcodeproj/project.pbxproj"
for name in BrainActor SpeechActor BrainResponseEvent BrainThoughtEvent SpeechPlaybackEvent \
            BrainActorTests SpeechActorTests LLMProvider CerebrasProvider ClaudeProvider; do
    grep -c "$name" "$PBXPROJ" && \
        sed -i '' "/$name/d" "$PBXPROJ" && \
        echo "Removed $name entries" || echo "No entries for $name (already clean)"
done
```
Expected: each filename prints "Removed X entries" with a count > 0.

- [ ] **Step 2: Verify no references remain**

```bash
grep -E "BrainActor|SpeechActor|BrainResponseEvent|BrainThoughtEvent|SpeechPlaybackEvent|BrainActorTests|SpeechActorTests|LLMProvider|CerebrasProvider|ClaudeProvider" \
    /Users/tpavankalyan/Downloads/Code/banti/Banti/Banti.xcodeproj/project.pbxproj
```
Expected: **no output** (grep exits non-zero silently — no matches)

---

### Task 3: Clean up BantiApp.swift

**Files:**
- Modify: `Banti/Banti/BantiApp.swift`

Replace the entire file with the perception-only version. Key changes:
- Remove `brain: BrainActor` and `speech: SpeechActor` stored properties
- Add `eventLogger: EventLoggerActor`
- Remove Brain/Speech from `init()` and `bootstrap()`
- Remove `dependencies: [brain.id]` from `sceneDesc` registration

- [ ] **Step 1: Overwrite BantiApp.swift**

Write the following content to `/Users/tpavankalyan/Downloads/Code/banti/Banti/Banti/BantiApp.swift`:

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
    @StateObject private var viewModel: TranscriptViewModel
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

        let vm = TranscriptViewModel(eventHub: hub)
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
            TranscriptView(viewModel: viewModel)
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
        vm: TranscriptViewModel
    ) async {
        let logger = Logger(subsystem: "com.banti.app", category: "Lifecycle")
        logger.notice("bootstrap entered")

        // Event logger registered first — subscribed before any module can publish.
        await sup.register(eventLogger, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        // Projection must subscribe to RawTranscriptEvent before mic starts.
        // Mic depends on both dg and proj so topo order is: proj → dg → mic.
        await sup.register(proj, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(dg, restartPolicy: .onFailure(maxRetries: 5, backoff: 1))
        await sup.register(mic, restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [dg.id, proj.id])
        // Camera pipeline: sceneDesc must subscribe to CameraFrameEvent before camera starts.
        await sup.register(sceneDesc, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
        await sup.register(camera, restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [sceneDesc.id])

        do {
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

---

### Task 4: Remove dead EnvKey constants from Environment.swift

**Files:**
- Modify: `Banti/Banti/Config/Environment.swift`

Remove the 7 keys that were only used by the deleted Brain/Action modules. Keep `anthropicAPIKey` and `anthropicVisionModel` (both used by `SceneDescriptionActor`).

- [ ] **Step 1: Overwrite Environment.swift**

Write the following content to `/Users/tpavankalyan/Downloads/Code/banti/Banti/Banti/Config/Environment.swift`:

```swift
import Foundation

enum EnvKey {
    static let deepgramAPIKey = "DEEPGRAM_API_KEY"
    static let deepgramModel = "DEEPGRAM_MODEL"
    static let deepgramLanguage = "DEEPGRAM_LANGUAGE"
    static let anthropicAPIKey = "ANTHROPIC_API_KEY"
    static let cameraCaptureIntervalMs   = "CAMERA_CAPTURE_INTERVAL_MS"
    static let visionProvider            = "VISION_PROVIDER"
    static let sceneDescriptionIntervalS = "SCENE_DESCRIPTION_INTERVAL_S"
    static let sceneDescriptionPrompt    = "SCENE_DESCRIPTION_PROMPT"
    static let anthropicVisionModel      = "ANTHROPIC_VISION_MODEL"
}
```

- [ ] **Step 2: Commit Tasks 1–4**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && \
git add Banti/Banti.xcodeproj/project.pbxproj \
        Banti/Banti/BantiApp.swift \
        Banti/Banti/Config/Environment.swift && \
git commit -m "feat: strip Brain/Action modules — keep perception pipeline only"
```

---

### Task 5: Create EventLoggerActor.swift

**Files:**
- Create: `Banti/Banti/Core/EventLoggerActor.swift`

- [ ] **Step 1: Write the file**

Create `/Users/tpavankalyan/Downloads/Code/banti/Banti/Banti/Core/EventLoggerActor.swift` with:

```swift
import Foundation
import os

/// Passive observer that logs every perception event to Console.app.
/// Filter in Console with: category == "EventLog"
actor EventLoggerActor: BantiModule {
    nonisolated let id = ModuleID("event-logger")
    nonisolated let capabilities: Set<Capability> = []

    private let logger = Logger(subsystem: "com.banti.core", category: "EventLog")
    private let eventHub: EventHubActor
    private var subscriptionIDs: [SubscriptionID] = []
    private var audioFrameCount: UInt64 = 0
    private var _health: ModuleHealth = .healthy

    init(eventHub: EventHubActor) {
        self.eventHub = eventHub
    }

    func start() async throws {
        subscriptionIDs.append(await eventHub.subscribe(AudioFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logAudio(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(CameraFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logCamera(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(RawTranscriptEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logRawTranscript(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(TranscriptSegmentEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logTranscriptSegment(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(SceneDescriptionEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logSceneDescription(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(ModuleStatusEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logModuleStatus(event)
        })
        _health = .healthy
        logger.notice("EventLoggerActor started — subscribed to 6 event types")
    }

    func stop() async {
        for subID in subscriptionIDs {
            await eventHub.unsubscribe(subID)
        }
        subscriptionIDs.removeAll()
    }

    func health() async -> ModuleHealth { _health }

    // MARK: - Per-event log methods

    private func logAudio(_ event: AudioFrameEvent) {
        audioFrameCount += 1
        guard audioFrameCount % 100 == 0 else { return }
        logger.debug("AudioFrame seq=\(event.sequenceNumber) bytes=\(event.audioData.count) sampleRate=\(event.sampleRate)")
    }

    private func logCamera(_ event: CameraFrameEvent) {
        logger.debug("CameraFrame seq=\(event.sequenceNumber) bytes=\(event.jpeg.count) size=\(event.frameWidth)x\(event.frameHeight)")
    }

    private func logRawTranscript(_ event: RawTranscriptEvent) {
        let speaker = event.speakerIndex.map { "Speaker \($0)" } ?? "unknown"
        logger.debug("RawTranscript speaker=\(speaker, privacy: .public) confidence=\(event.confidence, format: .fixed(precision: 2)) final=\(event.isFinal) text=\(String(event.text.prefix(80)), privacy: .public)")
    }

    private func logTranscriptSegment(_ event: TranscriptSegmentEvent) {
        logger.notice("TranscriptSegment speaker=\(event.speakerLabel, privacy: .public) final=\(event.isFinal) text=\(String(event.text.prefix(80)), privacy: .public)")
    }

    private func logSceneDescription(_ event: SceneDescriptionEvent) {
        let latencyMs = Int(event.responseTime.timeIntervalSince(event.captureTime) * 1000)
        logger.notice("SceneDescription latency=\(latencyMs)ms text=\(String(event.text.prefix(60)), privacy: .public)")
    }

    private func logModuleStatus(_ event: ModuleStatusEvent) {
        logger.notice("ModuleStatus module=\(event.moduleID.rawValue, privacy: .public) \(event.oldStatus, privacy: .public) → \(event.newStatus, privacy: .public)")
    }
}
```

- [ ] **Step 2: Add EventLoggerActor.swift to the Xcode project**

The pbxproj must be updated to include the new file, otherwise Xcode won't compile it. Use the following Python script to insert the new file reference into the `Core` group:

```bash
python3 - <<'EOF'
import re, uuid, subprocess

pbxproj = "/Users/tpavankalyan/Downloads/Code/banti/Banti/Banti.xcodeproj/project.pbxproj"
with open(pbxproj) as f:
    content = f.read()

# Generate stable-looking UUIDs (24 hex chars, uppercase)
file_ref_id = uuid.uuid4().hex[:24].upper()
build_file_id = uuid.uuid4().hex[:24].upper()

# Find an existing Core file reference to anchor our insertion
# EventHubActor.swift is definitely in Core/
anchor_ref = re.search(r'([A-F0-9]{24}) /\* EventHubActor\.swift \*/', content)
if not anchor_ref:
    print("ERROR: Could not find EventHubActor.swift anchor in pbxproj")
    exit(1)

anchor_uuid = anchor_ref.group(1)

# 1. Insert PBXFileReference entry after EventHubActor's file reference line
file_ref_line = f'\t\t{file_ref_id} /* EventLoggerActor.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = EventLoggerActor.swift; sourceTree = "<group>"; }};\n'
content = content.replace(
    f'{anchor_uuid} /* EventHubActor.swift */ = {{isa = PBXFileReference;',
    f'{file_ref_id} /* EventLoggerActor.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = EventLoggerActor.swift; sourceTree = "<group>"; }};\n\t\t{anchor_uuid} /* EventHubActor.swift */ = {{isa = PBXFileReference;'
)

# 2. Insert PBXBuildFile entry
build_file_line = f'\t\t{build_file_id} /* EventLoggerActor.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* EventLoggerActor.swift */; }};\n'
# Find any existing build file line as anchor
build_anchor = re.search(r'\t\t[A-F0-9]{24} /\* EventHubActor\.swift in Sources \*/', content)
if build_anchor:
    content = content.replace(
        build_anchor.group(0),
        f'\t\t{build_file_id} /* EventLoggerActor.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* EventLoggerActor.swift */; }};\n' + build_anchor.group(0)
    )

# 3. Add file ref to the Core group children list
content = content.replace(
    f'{anchor_uuid} /* EventHubActor.swift */,',
    f'{file_ref_id} /* EventLoggerActor.swift */,\n\t\t\t\t{anchor_uuid} /* EventHubActor.swift */,'
)

# 4. Add build file to Sources build phase
build_anchor2 = re.search(r'\t\t\t\t[A-F0-9]{24} /\* EventHubActor\.swift in Sources \*/', content)
if build_anchor2:
    content = content.replace(
        build_anchor2.group(0),
        f'\t\t\t\t{build_file_id} /* EventLoggerActor.swift in Sources */,\n' + build_anchor2.group(0)
    )

with open(pbxproj, 'w') as f:
    f.write(content)

print(f"Added EventLoggerActor.swift: fileRef={file_ref_id}, buildFile={build_file_id}")
EOF
```

Expected output: `Added EventLoggerActor.swift: fileRef=XXXXXXXXXXXXXXXXXXXXXXXX, buildFile=YYYYYYYYYYYYYYYYYYYYYYYY`

- [ ] **Step 3: Verify the new file appears in pbxproj**

```bash
grep "EventLoggerActor" /Users/tpavankalyan/Downloads/Code/banti/Banti/Banti.xcodeproj/project.pbxproj
```

Expected: 4 lines — one PBXFileReference, one PBXBuildFile, one group child entry, one Sources build phase entry.

- [ ] **Step 4: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && \
git add Banti/Banti/Core/EventLoggerActor.swift \
        Banti/Banti.xcodeproj/project.pbxproj && \
git commit -m "feat: add EventLoggerActor — passive observer logs all perception events"
```

---

### Task 6: Build verification

- [ ] **Step 1: Build the project**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti && \
xcodebuild -project Banti.xcodeproj \
           -scheme Banti \
           -destination 'platform=macOS' \
           build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`

If build fails, read the full error output:
```bash
xcodebuild -project Banti.xcodeproj -scheme Banti -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD FAILED"
```

Common failure modes and fixes:
- `use of unresolved identifier 'BrainActor'` → a reference to BrainActor remains in BantiApp.swift — recheck Task 3
- `cannot find type 'SpeechActor'` → same, check BantiApp.swift
- `use of unresolved identifier 'EnvKey.cerebrasAPIKey'` → check Task 4 Environment.swift cleanup
- `file not found: EventLoggerActor.swift` → pbxproj edit in Task 5 Step 2 failed — re-run the Python script

- [ ] **Step 2: Run the test suite**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti/Banti && \
xcodebuild -project Banti.xcodeproj \
           -scheme BantiTests \
           -destination 'platform=macOS' \
           test 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`

If tests fail, check for lingering references to deleted types in surviving test files by running:
```bash
grep -r "BrainActor\|SpeechActor\|BrainResponseEvent\|BrainThoughtEvent\|SpeechPlaybackEvent" \
    /Users/tpavankalyan/Downloads/Code/banti/Banti/BantiTests/
```
Expected: no output.
