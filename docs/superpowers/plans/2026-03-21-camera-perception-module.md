# Camera Perception Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a continuous camera capture pipeline to Banti, mirroring the microphone pipeline, starting with a `SceneDescriptionActor` that passively enriches `BrainActor`'s context with visual scene descriptions via a configurable `VisionProvider`.

**Architecture:** `CameraFrameActor` captures JPEG frames from `AVCaptureSession` continuously and publishes `CameraFrameEvent` to `EventHubActor`. `SceneDescriptionActor` subscribes independently, self-throttles, calls `VisionProvider.describe()`, and publishes `SceneDescriptionEvent`. `BrainActor` subscribes to scene descriptions and appends them passively to `context.md` without triggering the cognitive loop.

**Tech Stack:** Swift 6, Swift Concurrency (actors), AVFoundation (AVCaptureSession + AVCaptureVideoDataOutput), CoreImage (frame scaling), ImageIO (JPEG dimension extraction), AppKit, Anthropic Messages API (vision), XCTest.

---

## Important Notes for Implementers

**Running tests:** From the `Banti/` directory (where `Banti.xcodeproj` lives):
```bash
cd Banti && xcodebuild test -scheme Banti -destination 'platform=macOS' 2>&1 | tail -20
```

**Adding new Swift files to Xcode:** Every new `.swift` file must be added to the Xcode project or it won't compile. The safest approach: open `Banti/Banti.xcodeproj` in Xcode, right-click the target group, choose "Add Files to Banti". Alternatively, create the file via File > New > Swift File in Xcode (which auto-adds it), then replace its content.

Each task below has an explicit "Add to Xcode" step where files are created.

**Spec:** `docs/superpowers/specs/2026-03-21-camera-perception-module-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Banti/Banti/Core/CameraLatestFrameBuffer.swift` | Create | Thread-safe single-slot JPEG buffer (bridge between AVCapture callback and actor drain loop) |
| `Banti/Banti/Core/Events/CameraFrameEvent.swift` | Create | PerceptionEvent carrying JPEG data + metadata |
| `Banti/Banti/Core/Events/SceneDescriptionEvent.swift` | Create | PerceptionEvent carrying VLM text description |
| `Banti/Banti/Core/BantiModule.swift` | Modify | Add `.videoCapture` and `.sceneDescription` capabilities |
| `Banti/Banti/Config/Environment.swift` | Modify | Add 5 new env key constants |
| `Banti/Banti/Info.plist` | Modify | Add `NSCameraUsageDescription` |
| `Banti/Banti/Banti.entitlements` | Modify | Add camera entitlement |
| `Banti/Banti/Modules/Perception/Camera/VisionProvider.swift` | Create | `VisionProvider` protocol + `VisionError` |
| `Banti/Banti/Modules/Perception/Camera/Providers/ClaudeVisionProvider.swift` | Create | Anthropic messages API with base64 image content block |
| `Banti/Banti/Modules/Perception/Camera/CameraFrameActor.swift` | Create | `CameraFrameReplayProvider` protocol + AVCaptureSession tap + JPEG scaling + replay buffer + drain loop |
| `Banti/Banti/Modules/Perception/Camera/SceneDescriptionActor.swift` | Create | Throttled VisionProvider calls, publishes SceneDescriptionEvent |
| `Banti/Banti/Modules/Brain/BrainActor.swift` | Modify | Second subscription to SceneDescriptionEvent, passive context append |
| `Banti/Banti/BantiApp.swift` | Modify | Wire camera + sceneDesc actors, register with supervisor |
| `Banti/BantiTests/CameraLatestFrameBufferTests.swift` | Create | Unit tests for buffer store/take/overwrite |
| `Banti/BantiTests/Helpers/MockVisionProvider.swift` | Create | Injected VisionProvider for tests with optional `onCall` callback |
| `Banti/BantiTests/SceneDescriptionActorTests.swift` | Create | Tests for throttle, publish, health degradation |
| `Banti/BantiTests/CameraFrameActorTests.swift` | Create | Tests for capabilities, replay buffer |

---

## Task 1: Foundation — Buffer, Events, Capabilities, EnvKeys, Platform

**Files:**
- Create: `Banti/Banti/Core/CameraLatestFrameBuffer.swift`
- Create: `Banti/Banti/Core/Events/CameraFrameEvent.swift`
- Create: `Banti/Banti/Core/Events/SceneDescriptionEvent.swift`
- Modify: `Banti/Banti/Core/BantiModule.swift`
- Modify: `Banti/Banti/Config/Environment.swift`
- Modify: `Banti/Banti/Info.plist`
- Modify: `Banti/Banti/Banti.entitlements`
- Create: `Banti/BantiTests/CameraLatestFrameBufferTests.swift`

- [ ] **Step 1: Write the failing test for CameraLatestFrameBuffer**

Create `Banti/BantiTests/CameraLatestFrameBufferTests.swift` and add to Xcode (BantiTests target):

```swift
import XCTest
@testable import Banti

final class CameraLatestFrameBufferTests: XCTestCase {
    func testTakeReturnsNilWhenEmpty() {
        let buffer = CameraLatestFrameBuffer()
        XCTAssertNil(buffer.take())
    }

    func testStoreAndTake() {
        let buffer = CameraLatestFrameBuffer()
        let data = Data("frame".utf8)
        buffer.store(data)
        XCTAssertEqual(buffer.take(), data)
    }

    func testTakeClearsBuffer() {
        let buffer = CameraLatestFrameBuffer()
        buffer.store(Data("frame".utf8))
        _ = buffer.take()
        XCTAssertNil(buffer.take())
    }

    func testStoreOverwritesPreviousFrame() {
        let buffer = CameraLatestFrameBuffer()
        buffer.store(Data("frame1".utf8))
        buffer.store(Data("frame2".utf8))
        XCTAssertEqual(buffer.take(), Data("frame2".utf8))
    }
}
```

Add this file to the Xcode project (BantiTests target).

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd Banti && xcodebuild test -scheme Banti -destination 'platform=macOS' 2>&1 | grep -E "error:|CameraLatest" | head -10
```

Expected: compile error — `CameraLatestFrameBuffer` not found.

- [ ] **Step 3: Create CameraLatestFrameBuffer**

Create `Banti/Banti/Core/CameraLatestFrameBuffer.swift` and add to Xcode (Banti target):

```swift
import Foundation

final class CameraLatestFrameBuffer: @unchecked Sendable {
    private var latest: Data?
    private let lock = NSLock()

    func store(_ jpeg: Data) {
        lock.withLock { latest = jpeg }
    }

    func take() -> Data? {
        lock.withLock {
            defer { latest = nil }
            return latest
        }
    }
}
```

- [ ] **Step 4: Create CameraFrameEvent**

Create `Banti/Banti/Core/Events/CameraFrameEvent.swift` and add to Xcode (Banti target):

```swift
import Foundation

struct CameraFrameEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let jpeg: Data
    let sequenceNumber: UInt64
    let frameWidth: Int
    let frameHeight: Int

    init(jpeg: Data, sequenceNumber: UInt64, frameWidth: Int, frameHeight: Int) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("camera-capture")
        self.jpeg = jpeg
        self.sequenceNumber = sequenceNumber
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }
}
```

- [ ] **Step 5: Create SceneDescriptionEvent**

Create `Banti/Banti/Core/Events/SceneDescriptionEvent.swift` and add to Xcode (Banti target):

```swift
import Foundation

struct SceneDescriptionEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let text: String
    let captureTime: Date
    let responseTime: Date

    init(text: String, captureTime: Date, responseTime: Date) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("scene-description")
        self.text = text
        self.captureTime = captureTime
        self.responseTime = responseTime
    }
}
```

- [ ] **Step 6: Add capabilities and EnvKeys**

In `Banti/Banti/Core/BantiModule.swift`, add after `static let speech = Capability("speech")`:

```swift
static let videoCapture     = Capability("video-capture")
static let sceneDescription = Capability("scene-description")
```

In `Banti/Banti/Config/Environment.swift`, add after the last existing key:

```swift
static let cameraCaptureIntervalMs   = "CAMERA_CAPTURE_INTERVAL_MS"
static let visionProvider            = "VISION_PROVIDER"
static let sceneDescriptionIntervalS = "SCENE_DESCRIPTION_INTERVAL_S"
static let sceneDescriptionPrompt    = "SCENE_DESCRIPTION_PROMPT"
static let anthropicVisionModel      = "ANTHROPIC_VISION_MODEL"
```

- [ ] **Step 7: Add platform permissions**

In `Banti/Banti/Info.plist`, add inside the `<dict>` before the closing `</dict>`:

```xml
<key>NSCameraUsageDescription</key>
<string>Banti uses the camera to understand the visual scene and provide context-aware assistance.</string>
```

In `Banti/Banti/Banti.entitlements`, replace the empty `<dict/>` with:

```xml
<dict>
    <key>com.apple.security.device.camera</key>
    <true/>
</dict>
```

- [ ] **Step 8: Run tests to confirm buffer tests pass**

```bash
cd Banti && xcodebuild test -scheme Banti -destination 'platform=macOS' 2>&1 | grep -E "(CameraLatestFrameBuffer|PASS|FAIL|error:)" | head -20
```

Expected: all 4 `CameraLatestFrameBufferTests` pass, no new failures.

- [ ] **Step 9: Commit**

```bash
git add Banti/Banti/Core/CameraLatestFrameBuffer.swift \
        Banti/Banti/Core/Events/CameraFrameEvent.swift \
        Banti/Banti/Core/Events/SceneDescriptionEvent.swift \
        Banti/Banti/Core/BantiModule.swift \
        Banti/Banti/Config/Environment.swift \
        Banti/Banti/Info.plist \
        Banti/Banti/Banti.entitlements \
        Banti/BantiTests/CameraLatestFrameBufferTests.swift \
        Banti/Banti.xcodeproj/project.pbxproj
git commit -m "feat: camera perception foundation — events, buffer, capabilities, env keys"
```

---

## Task 2: VisionProvider Protocol + ClaudeVisionProvider

**Files:**
- Create: `Banti/Banti/Modules/Perception/Camera/VisionProvider.swift`
- Create: `Banti/Banti/Modules/Perception/Camera/Providers/ClaudeVisionProvider.swift`
- Create: `Banti/BantiTests/Helpers/MockVisionProvider.swift`
- Create: `Banti/BantiTests/ClaudeVisionProviderTests.swift`

- [ ] **Step 1: Write the failing compilation test**

Create `Banti/BantiTests/ClaudeVisionProviderTests.swift` and add to Xcode (BantiTests target):

```swift
import XCTest
@testable import Banti

final class ClaudeVisionProviderTests: XCTestCase {
    func testInitializesWithApiKeyAndDefaultModel() {
        let provider = ClaudeVisionProvider(apiKey: "test-key")
        // Compiles means the type exists and conforms to VisionProvider.
        let _: any VisionProvider = provider
    }

    func testInitializesWithCustomModel() {
        let provider = ClaudeVisionProvider(apiKey: "test-key", model: "claude-opus-4-6")
        let _: any VisionProvider = provider
        XCTAssertEqual(provider.model, "claude-opus-4-6")
    }
}
```

Add to Xcode. Run tests to confirm compile error:

```bash
cd Banti && xcodebuild test -scheme Banti -destination 'platform=macOS' 2>&1 | grep "error:" | head -5
```

- [ ] **Step 2: Create VisionProvider protocol**

Create `Banti/Banti/Modules/Perception/Camera/VisionProvider.swift` and add to Xcode (Banti target). Create the `Camera/` and `Camera/Providers/` directory groups in Xcode first.

```swift
import Foundation

// MARK: - VisionProvider

protocol VisionProvider: Sendable {
    func describe(jpeg: Data, prompt: String) async throws -> String
}

// MARK: - VisionError

struct VisionError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
```

Note: `CameraFrameReplayProvider` is defined in `CameraFrameActor.swift` (Task 3), co-located with its implementer — matching the pattern of `AudioFrameReplayProvider` in `MicrophoneCaptureActor.swift`.

- [ ] **Step 3: Create ClaudeVisionProvider**

Create `Banti/Banti/Modules/Perception/Camera/Providers/ClaudeVisionProvider.swift` and add to Xcode (Banti target):

```swift
import Foundation
import os

struct ClaudeVisionProvider: VisionProvider {
    private let logger = Logger(subsystem: "com.banti.vision", category: "Claude")

    private let apiKey: String
    let model: String  // internal let — exposed for testability

    static let defaultModel = "claude-haiku-4-5"

    init(apiKey: String, model: String = ClaudeVisionProvider.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    func describe(jpeg: Data, prompt: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let base64Image = jpeg.base64EncodedString()
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ],
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw VisionError("Invalid response from Claude Vision")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw VisionError("Claude Vision \(http.statusCode): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String
        else {
            throw VisionError("Unexpected Claude Vision response format")
        }

        logger.notice("Scene described: \(text.prefix(80), privacy: .public)")
        return text
    }
}
```

- [ ] **Step 4: Create MockVisionProvider for tests**

Create `Banti/BantiTests/Helpers/MockVisionProvider.swift` and add to Xcode (BantiTests target):

```swift
import Foundation
@testable import Banti

struct MockVisionProvider: VisionProvider {
    let result: Result<String, Error>
    // Optional callback invoked when describe() is called — use to synchronize tests.
    let onCall: (@Sendable () -> Void)?

    init(returning description: String, onCall: (@Sendable () -> Void)? = nil) {
        self.result = .success(description)
        self.onCall = onCall
    }

    init(throwing error: Error, onCall: (@Sendable () -> Void)? = nil) {
        self.result = .failure(error)
        self.onCall = onCall
    }

    func describe(jpeg: Data, prompt: String) async throws -> String {
        onCall?()
        switch result {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }
}
```

- [ ] **Step 5: Run tests to confirm ClaudeVisionProviderTests pass**

```bash
cd Banti && xcodebuild test -scheme Banti -destination 'platform=macOS' 2>&1 | grep -E "(ClaudeVisionProvider|PASS|FAIL|error:)" | head -10
```

Expected: both `ClaudeVisionProviderTests` pass.

- [ ] **Step 6: Commit**

```bash
git add Banti/Banti/Modules/Perception/Camera/VisionProvider.swift \
        Banti/Banti/Modules/Perception/Camera/Providers/ClaudeVisionProvider.swift \
        Banti/BantiTests/Helpers/MockVisionProvider.swift \
        Banti/BantiTests/ClaudeVisionProviderTests.swift \
        Banti/Banti.xcodeproj/project.pbxproj
git commit -m "feat: VisionProvider protocol and ClaudeVisionProvider"
```

---

## Task 3: CameraFrameActor

**Files:**
- Create: `Banti/Banti/Modules/Perception/Camera/CameraFrameActor.swift`
- Create: `Banti/BantiTests/CameraFrameActorTests.swift`

`CameraFrameReplayProvider` is defined in `CameraFrameActor.swift`, co-located with its implementer (same as `AudioFrameReplayProvider` in `MicrophoneCaptureActor.swift`).

- [ ] **Step 1: Write the failing tests**

Create `Banti/BantiTests/CameraFrameActorTests.swift` and add to Xcode (BantiTests target):

```swift
import XCTest
@testable import Banti

final class CameraFrameActorTests: XCTestCase {
    func testCapabilitiesIncludesVideoCapture() {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = CameraFrameActor(eventHub: hub, config: config)
        XCTAssertTrue(actor.capabilities.contains(.videoCapture))
    }

    func testIdIsCorrect() {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = CameraFrameActor(eventHub: hub, config: config)
        XCTAssertEqual(actor.id.rawValue, "camera-capture")
    }

    func testReplayFramesReturnsEmptyWhenNothingPublished() async {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = CameraFrameActor(eventHub: hub, config: config)
        let frames = await actor.replayFrames(after: 0)
        XCTAssertTrue(frames.isEmpty)
    }

    func testReplayFramesReturnsFramesAfterSeq() async {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = CameraFrameActor(eventHub: hub, config: config)

        // Inject frames directly via the test-only method.
        await actor.injectFrameForTesting(jpeg: Data("frame1".utf8), seq: 1)
        await actor.injectFrameForTesting(jpeg: Data("frame2".utf8), seq: 2)
        await actor.injectFrameForTesting(jpeg: Data("frame3".utf8), seq: 3)

        let frames = await actor.replayFrames(after: 1)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].seq, 2)
        XCTAssertEqual(frames[1].seq, 3)
    }

    func testReplayBufferEvictsOldFrames() async {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = CameraFrameActor(eventHub: hub, config: config)

        // Inject 31 frames — one more than the maxReplayFrames (30).
        for i in UInt64(1)...31 {
            await actor.injectFrameForTesting(jpeg: Data("frame\(i)".utf8), seq: i)
        }

        let frames = await actor.replayFrames(after: 0)
        // Should have at most 30, and oldest (seq=1) should be evicted.
        XCTAssertEqual(frames.count, 30)
        XCTAssertEqual(frames.first?.seq, 2, "Oldest frame should be evicted")
        XCTAssertEqual(frames.last?.seq, 31)
    }

    func testHealthIsHealthyAfterInit() async {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = CameraFrameActor(eventHub: hub, config: config)
        let health = await actor.health()
        if case .healthy = health { /* pass */ } else {
            XCTFail("Expected healthy, got \(health.label)")
        }
    }
}
```

Run to confirm compile error:

```bash
cd Banti && xcodebuild test -scheme Banti -destination 'platform=macOS' 2>&1 | grep "error:" | head -5
```

- [ ] **Step 2: Create CameraFrameActor**

Create `Banti/Banti/Modules/Perception/Camera/CameraFrameActor.swift` and add to Xcode (Banti target):

```swift
import Foundation
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import AppKit
import os

// MARK: - CameraFrameReplayProvider
// Co-located with its implementer, matching the AudioFrameReplayProvider pattern.

protocol CameraFrameReplayProvider: Actor {
    func replayFrames(after lastSeq: UInt64) async -> [(seq: UInt64, data: Data)]
}

// MARK: - CameraFrameActor

actor CameraFrameActor: BantiModule, CameraFrameReplayProvider {
    nonisolated let id = ModuleID("camera-capture")
    nonisolated let capabilities: Set<Capability> = [.videoCapture]

    private let logger = Logger(subsystem: "com.banti.camera-capture", category: "Capture")
    private let eventHub: EventHubActor
    private let config: ConfigActor

    private var captureSession: AVCaptureSession?
    private var drainTask: Task<Void, Never>?
    private var sequenceNumber: UInt64 = 0
    private var publishedFrameCount = 0
    private let frameBuffer = CameraLatestFrameBuffer()
    private var _health: ModuleHealth = .healthy

    private var replayBuffer: [(seq: UInt64, data: Data)] = []
    private let maxReplayFrames = 30

    // Inner class: bridges AVFoundation delegate callback (non-isolated) to actor-safe buffer.
    private final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let buffer: CameraLatestFrameBuffer

        init(buffer: CameraLatestFrameBuffer) {
            self.buffer = buffer
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let jpeg = sampleBuffer.toScaledJPEG(maxEdge: 1280, quality: 0.7) else { return }
            buffer.store(jpeg)
        }
    }

    private var captureDelegate: CaptureDelegate?

    init(eventHub: EventHubActor, config: ConfigActor) {
        self.eventHub = eventHub
        self.config = config
    }

    func start() async throws {
        let intervalMs = Int((await config.value(for: EnvKey.cameraCaptureIntervalMs))
            .flatMap(Int.init) ?? 200)

        let session = AVCaptureSession()
        session.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
            _health = .failed(error: ConfigError(message: "No camera device available"))
            throw ConfigError(message: "No camera device available")
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw ConfigError(message: "Cannot add camera input to session")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true

        let captureQueue = DispatchQueue(label: "com.banti.camera-capture", qos: .userInitiated)
        let delegate = CaptureDelegate(buffer: frameBuffer)
        output.setSampleBufferDelegate(delegate, queue: captureQueue)
        self.captureDelegate = delegate

        guard session.canAddOutput(output) else {
            throw ConfigError(message: "Cannot add video output to session")
        }
        session.addOutput(output)

        session.startRunning()
        self.captureSession = session
        _health = .healthy
        logger.notice("Camera capture session started (interval=\(intervalMs)ms)")

        startDrainTask(intervalMs: intervalMs)
    }

    func stop() async {
        drainTask?.cancel()
        drainTask = nil
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
        logger.info("Camera capture session stopped")
    }

    func health() -> ModuleHealth { _health }

    func replayFrames(after lastSeq: UInt64) -> [(seq: UInt64, data: Data)] {
        replayBuffer.filter { $0.seq > lastSeq }
    }

    // Used by tests to inject frames without starting AVCaptureSession.
    func injectFrameForTesting(jpeg: Data, seq: UInt64) {
        replayBuffer.append((seq: seq, data: jpeg))
        if replayBuffer.count > maxReplayFrames {
            replayBuffer.removeFirst()
        }
    }

    private func startDrainTask(intervalMs: Int) {
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(intervalMs))
                guard let self else { return }
                await self.drainLatestFrame()
            }
        }
    }

    private func drainLatestFrame() async {
        guard let jpeg = frameBuffer.take() else { return }

        sequenceNumber += 1
        publishedFrameCount += 1

        let (width, height) = jpegDimensions(jpeg)

        let event = CameraFrameEvent(
            jpeg: jpeg,
            sequenceNumber: sequenceNumber,
            frameWidth: width,
            frameHeight: height
        )

        replayBuffer.append((seq: sequenceNumber, data: jpeg))
        if replayBuffer.count > maxReplayFrames {
            replayBuffer.removeFirst()
        }

        await eventHub.publish(event)

        if publishedFrameCount == 1 || publishedFrameCount.isMultiple(of: 50) {
            logger.notice("Published \(self.publishedFrameCount) camera frames")
        }
    }

    private func jpegDimensions(_ data: Data) -> (Int, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return (0, 0) }
        return (w, h)
    }
}

// MARK: - CMSampleBuffer → Scaled JPEG

private extension CMSampleBuffer {
    func toScaledJPEG(maxEdge: CGFloat, quality: CGFloat) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(self) else { return nil }

        let width = CGFloat(CVPixelBufferGetWidth(imageBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(imageBuffer))
        let scale = min(1.0, maxEdge / max(width, height))

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let scaled = scale < 1.0
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
```

- [ ] **Step 3: Run tests to confirm CameraFrameActorTests pass**

```bash
cd Banti && xcodebuild test -scheme Banti -destination 'platform=macOS' 2>&1 | grep -E "(CameraFrameActor|PASS|FAIL|error:)" | head -10
```

Expected: all 5 `CameraFrameActorTests` pass.

- [ ] **Step 4: Commit**

```bash
git add Banti/Banti/Modules/Perception/Camera/CameraFrameActor.swift \
        Banti/BantiTests/CameraFrameActorTests.swift \
        Banti/Banti.xcodeproj/project.pbxproj
git commit -m "feat: CameraFrameActor — continuous capture with JPEG scaling and replay buffer"
```

---

## Task 4: SceneDescriptionActor

**Files:**
- Create: `Banti/Banti/Modules/Perception/Camera/SceneDescriptionActor.swift`
- Create: `Banti/BantiTests/SceneDescriptionActorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Banti/BantiTests/SceneDescriptionActorTests.swift` and add to Xcode (BantiTests target):

```swift
import XCTest
@testable import Banti

final class SceneDescriptionActorTests: XCTestCase {

    private func makeFrame(seq: UInt64 = 1) -> CameraFrameEvent {
        CameraFrameEvent(
            jpeg: Data("fake-jpeg".utf8),
            sequenceNumber: seq,
            frameWidth: 640,
            frameHeight: 480
        )
    }

    func testCapabilitiesIncludesSceneDescription() {
        let hub = EventHubActor()
        let config = ConfigActor(content: "")
        let actor = SceneDescriptionActor(eventHub: hub, config: config, provider: MockVisionProvider(returning: ""))
        XCTAssertTrue(actor.capabilities.contains(.sceneDescription))
    }

    func testPublishesSceneDescriptionEventOnFrame() async throws {
        let hub = EventHubActor()
        // Interval 0 means no throttling — every frame triggers a description.
        let config = ConfigActor(content: "SCENE_DESCRIPTION_INTERVAL_S=0")
        let exp = XCTestExpectation(description: "scene description received")
        let provider = MockVisionProvider(returning: "A person at a desk.") {
            // Signal that describe() was called — but we wait for the EventHub event.
        }
        let descriptions = TestRecorder<SceneDescriptionEvent>()

        _ = await hub.subscribe(SceneDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = SceneDescriptionActor(eventHub: hub, config: config, provider: provider)
        try await actor.start()

        await hub.publish(makeFrame())
        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.text, "A person at a desk.")
    }

    func testThrottlesWithinInterval() async throws {
        let hub = EventHubActor()
        // 10 second interval — second frame should be ignored within the interval.
        let config = ConfigActor(content: "SCENE_DESCRIPTION_INTERVAL_S=10")
        let firstExp = XCTestExpectation(description: "first scene published")
        let descriptions = TestRecorder<SceneDescriptionEvent>()

        _ = await hub.subscribe(SceneDescriptionEvent.self) { event in
            await descriptions.append(event)
            firstExp.fulfill()
        }

        let actor = SceneDescriptionActor(
            eventHub: hub,
            config: config,
            provider: MockVisionProvider(returning: "Scene.")
        )
        try await actor.start()

        // First frame — should publish.
        await hub.publish(makeFrame(seq: 1))
        await fulfillment(of: [firstExp], timeout: 3)

        // Second frame immediately after — should be throttled.
        await hub.publish(makeFrame(seq: 2))
        try await Task.sleep(for: .milliseconds(200))

        let snapshot = await descriptions.snapshot()
        XCTAssertEqual(snapshot.count, 1, "Second frame within 10s interval should be throttled")
    }

    func testVLMFailureDegradessHealth() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCENE_DESCRIPTION_INTERVAL_S=0")

        // Use onCall to know precisely when describe() executes — then health degrades synchronously after.
        let callExp = XCTestExpectation(description: "VLM called")
        let provider = MockVisionProvider(throwing: VisionError("API unavailable")) {
            callExp.fulfill()
        }

        let actor = SceneDescriptionActor(eventHub: hub, config: config, provider: provider)
        try await actor.start()

        await hub.publish(makeFrame())

        // Wait for the VLM call to execute.
        await fulfillment(of: [callExp], timeout: 3)

        // Give the actor one scheduling cycle to update _health after the throw.
        try await Task.sleep(for: .milliseconds(50))

        let health = await actor.health()
        if case .degraded = health { /* pass */ } else {
            XCTFail("Expected degraded health after VLM failure, got \(health.label)")
        }
    }

    func testCaptureTimeMatchesFrameTimestamp() async throws {
        let hub = EventHubActor()
        let config = ConfigActor(content: "SCENE_DESCRIPTION_INTERVAL_S=0")
        let exp = XCTestExpectation(description: "description received")
        let descriptions = TestRecorder<SceneDescriptionEvent>()

        _ = await hub.subscribe(SceneDescriptionEvent.self) { event in
            await descriptions.append(event)
            exp.fulfill()
        }

        let actor = SceneDescriptionActor(
            eventHub: hub,
            config: config,
            provider: MockVisionProvider(returning: "Test scene.")
        )
        try await actor.start()

        let beforePublish = Date()
        await hub.publish(makeFrame())

        await fulfillment(of: [exp], timeout: 3)

        let snapshot = await descriptions.snapshot()
        guard let first = snapshot.first else { XCTFail("No event received"); return }

        // captureTime should be close to the frame creation time.
        XCTAssertLessThan(abs(first.captureTime.timeIntervalSince(beforePublish)), 1.0,
                          "captureTime should match frame.timestamp, not VLM response time")
        // responseTime must be after captureTime.
        XCTAssertGreaterThanOrEqual(first.responseTime, first.captureTime)
    }
}
```

Run to confirm compile error:

```bash
cd Banti && xcodebuild test -scheme Banti -destination 'platform=macOS' 2>&1 | grep "error:" | head -5
```

- [ ] **Step 2: Create SceneDescriptionActor**

Create `Banti/Banti/Modules/Perception/Camera/SceneDescriptionActor.swift` and add to Xcode (Banti target):

```swift
import Foundation
import os

actor SceneDescriptionActor: BantiModule {
    nonisolated let id = ModuleID("scene-description")
    nonisolated let capabilities: Set<Capability> = [.sceneDescription]

    private let logger = Logger(subsystem: "com.banti.scene-description", category: "Scene")
    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let replayProvider: (any CameraFrameReplayProvider)?
    private let overrideProvider: (any VisionProvider)?

    private var subscriptionID: SubscriptionID?
    private var _health: ModuleHealth = .healthy
    private var lastDescribedAt: Date?
    private var describedCount = 0

    init(
        eventHub: EventHubActor,
        config: ConfigActor,
        replayProvider: (any CameraFrameReplayProvider)? = nil,
        provider: (any VisionProvider)? = nil
    ) {
        self.eventHub = eventHub
        self.config = config
        self.replayProvider = replayProvider
        self.overrideProvider = provider
    }

    func start() async throws {
        let provider = try await buildProvider()

        let intervalS = Double((await config.value(for: EnvKey.sceneDescriptionIntervalS))
            .flatMap(Double.init) ?? 5.0)
        let prompt = (await config.value(for: EnvKey.sceneDescriptionPrompt))
            ?? "Describe the visual scene concisely, focusing on people, objects, and activities."

        subscriptionID = await eventHub.subscribe(CameraFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleFrame(event, provider: provider, intervalS: intervalS, prompt: prompt)
        }

        _health = .healthy
        logger.notice("SceneDescriptionActor started (interval=\(intervalS)s)")
    }

    func stop() async {
        if let id = subscriptionID {
            await eventHub.unsubscribe(id)
            subscriptionID = nil
        }
    }

    func health() -> ModuleHealth { _health }

    private func handleFrame(
        _ event: CameraFrameEvent,
        provider: any VisionProvider,
        intervalS: Double,
        prompt: String
    ) async {
        // Throttle: skip if not enough time has elapsed since last successful description.
        if let last = lastDescribedAt, Date().timeIntervalSince(last) < intervalS {
            return
        }

        let captureTime = event.timestamp

        do {
            let description = try await provider.describe(jpeg: event.jpeg, prompt: prompt)
            let responseTime = Date()

            lastDescribedAt = responseTime
            describedCount += 1
            _health = .healthy

            let sceneEvent = SceneDescriptionEvent(
                text: description,
                captureTime: captureTime,
                responseTime: responseTime
            )
            await eventHub.publish(sceneEvent)

            if describedCount == 1 || describedCount.isMultiple(of: 10) {
                logger.notice("Published scene #\(self.describedCount): \(description.prefix(60), privacy: .public)")
            }
        } catch {
            logger.error("VisionProvider error: \(error.localizedDescription, privacy: .public)")
            _health = .degraded(reason: "VLM call failed: \(error.localizedDescription)")
        }
    }

    private func buildProvider() async throws -> any VisionProvider {
        if let override = overrideProvider { return override }

        let selected = ((await config.value(for: EnvKey.visionProvider)) ?? "claude")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch selected {
        case "claude":
            let key = try await config.require(EnvKey.anthropicAPIKey)
            let model = (await config.value(for: EnvKey.anthropicVisionModel)) ?? ClaudeVisionProvider.defaultModel
            logger.notice("Vision using Claude (\(model, privacy: .public))")
            return ClaudeVisionProvider(apiKey: key, model: model)

        default:
            throw VisionError("Unknown VISION_PROVIDER: \(selected). Supported: claude")
        }
    }
}
```

- [ ] **Step 3: Run all tests**

```bash
cd Banti && xcodebuild test -scheme Banti -destination 'platform=macOS' 2>&1 | grep -E "(SceneDescription|PASS|FAIL|error:)" | head -20
```

Expected: all 5 `SceneDescriptionActorTests` pass, no regressions.

- [ ] **Step 4: Commit**

```bash
git add Banti/Banti/Modules/Perception/Camera/SceneDescriptionActor.swift \
        Banti/BantiTests/SceneDescriptionActorTests.swift \
        Banti/Banti.xcodeproj/project.pbxproj
git commit -m "feat: SceneDescriptionActor — throttled VLM scene descriptions via VisionProvider"
```

---

## Task 5: BrainActor Integration

**Files:**
- Modify: `Banti/Banti/Modules/Brain/BrainActor.swift`
- Modify: `Banti/BantiTests/BrainActorTests.swift`

The brain passively appends scene descriptions to `context.md`. It does NOT debounce them, call the LLM, or touch `pendingText`.

- [ ] **Step 1: Write the failing tests**

Append these two test methods to the existing `BrainActorTests` class in `Banti/BantiTests/BrainActorTests.swift`:

```swift
func testSceneDescriptionDoesNotTriggerCognitiveLoop() async throws {
    let hub = EventHubActor()
    let config = ConfigActor(content: "ANTHROPIC_API_KEY=test-key")
    var decisionCalled = false

    let brain = BrainActor(
        eventHub: hub,
        config: config,
        debounceDuration: .milliseconds(50),
        contextFilePath: tempContextPath
    ) { _, _ in
        decisionCalled = true
        return BrainDecision(action: "wait", content: "")
    }

    try await brain.start()

    await hub.publish(SceneDescriptionEvent(
        text: "A person at a desk with two monitors.",
        captureTime: Date(),
        responseTime: Date()
    ))

    // Wait longer than the debounce to confirm the cognitive loop never fires.
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertFalse(decisionCalled, "SceneDescriptionEvent must not trigger the cognitive loop")
}

func testSceneDescriptionIsWrittenToContextFile() async throws {
    let hub = EventHubActor()
    let config = ConfigActor(content: "ANTHROPIC_API_KEY=test-key")

    let brain = BrainActor(
        eventHub: hub,
        config: config,
        debounceDuration: .milliseconds(50),
        contextFilePath: tempContextPath
    ) { _, _ in
        BrainDecision(action: "wait", content: "")
    }

    try await brain.start()

    await hub.publish(SceneDescriptionEvent(
        text: "Coffee cup on the desk.",
        captureTime: Date(),
        responseTime: Date()
    ))

    // Poll the file until the write completes or timeout is reached.
    // This is more reliable than a fixed sleep — the actor may be slower under load.
    let deadline = Date().addingTimeInterval(3)
    var found = false
    while Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
        let context = (try? String(contentsOfFile: tempContextPath, encoding: .utf8)) ?? ""
        if context.contains("Coffee cup on the desk.") {
            found = true
            break
        }
    }

    XCTAssertTrue(found, "Scene description was not written to context.md within timeout")

    let context = try String(contentsOfFile: tempContextPath, encoding: .utf8)
    XCTAssertTrue(context.contains("(scene)"), "Context must contain (scene) tag")
}
```

Run to confirm they fail:

```bash
cd Banti && xcodebuild test -scheme Banti -destination 'platform=macOS' 2>&1 | grep -E "(testScene|FAIL|error:)" | head -10
```

- [ ] **Step 2: Modify BrainActor**

In `Banti/Banti/Modules/Brain/BrainActor.swift`:

**2a.** Add a second subscription ID property. Find the line:
```swift
private var transcriptSubscriptionID: SubscriptionID?
```
Add after it:
```swift
private var sceneSubscriptionID: SubscriptionID?
```

**2b.** In `start()`, after the existing `transcriptSubscriptionID = await eventHub.subscribe(...)` block, add:
```swift
sceneSubscriptionID = await eventHub.subscribe(SceneDescriptionEvent.self) { [weak self] event in
    guard let self else { return }
    await self.handleSceneDescription(event)
}
```

**2c.** In `stop()`, after the existing unsubscription block, add:
```swift
if let id = sceneSubscriptionID {
    await eventHub.unsubscribe(id)
    sceneSubscriptionID = nil
}
```

**2d.** Add a new private method. Place it just before the `// MARK: - Working memory (context.md)` comment:
```swift
private func handleSceneDescription(_ event: SceneDescriptionEvent) {
    let timestamp = Self.timestamp()
    appendToContext("[\(timestamp)] (scene) \"\(event.text)\"")
    logger.notice("Scene appended to context: \(event.text.prefix(60), privacy: .public)")
}
```

- [ ] **Step 3: Run all tests**

```bash
cd Banti && xcodebuild test -scheme Banti -destination 'platform=macOS' 2>&1 | grep -E "(PASS|FAIL|error:)" | tail -30
```

Expected: all tests pass including both new BrainActor tests. Confirm no regressions in existing tests.

- [ ] **Step 4: Commit**

```bash
git add Banti/Banti/Modules/Brain/BrainActor.swift \
        Banti/BantiTests/BrainActorTests.swift
git commit -m "feat: BrainActor passively appends scene descriptions to context.md"
```

---

## Task 6: BantiApp Wiring

**Files:**
- Modify: `Banti/Banti/BantiApp.swift`

No unit tests — this is integration wiring. Verify by building.

- [ ] **Step 1: Add stored properties**

In `Banti/Banti/BantiApp.swift`, find the existing stored properties block:
```swift
private let speech: SpeechActor
```
Add after it:
```swift
private let camera: CameraFrameActor
private let sceneDesc: SceneDescriptionActor
```

- [ ] **Step 2: Instantiate actors in init()**

In `init()`, find:
```swift
let speechActor = SpeechActor(eventHub: hub, config: cfg)
```
Add after it:
```swift
let cameraActor = CameraFrameActor(eventHub: hub, config: cfg)
let sceneDescActor = SceneDescriptionActor(eventHub: hub, config: cfg, replayProvider: cameraActor)
```

Find the self-assignment block:
```swift
self.speech = speechActor
```
Add after it:
```swift
self.camera = cameraActor
self.sceneDesc = sceneDescActor
```

Update the `Task { await Self.bootstrap(...) }` call to pass the new actors:
```swift
Task {
    await Self.bootstrap(
        sup: sup, mic: mic, dg: dg, proj: proj,
        brain: brainActor, speech: speechActor,
        camera: cameraActor, sceneDesc: sceneDescActor, vm: vm
    )
}
```

- [ ] **Step 3: Update bootstrap() signature and body**

Update the `bootstrap` function signature. Find:
```swift
private static func bootstrap(
    sup: ModuleSupervisorActor,
    mic: MicrophoneCaptureActor,
    dg: DeepgramStreamingActor,
    proj: TranscriptProjectionActor,
    brain: BrainActor,
    speech: SpeechActor,
    vm: TranscriptViewModel
) async {
```
Replace with:
```swift
private static func bootstrap(
    sup: ModuleSupervisorActor,
    mic: MicrophoneCaptureActor,
    dg: DeepgramStreamingActor,
    proj: TranscriptProjectionActor,
    brain: BrainActor,
    speech: SpeechActor,
    camera: CameraFrameActor,
    sceneDesc: SceneDescriptionActor,
    vm: TranscriptViewModel
) async {
```

In the bootstrap body, find:
```swift
await sup.register(proj, restartPolicy: .onFailure(maxRetries: 3, backoff: 1))
```
Add these two lines BEFORE it (brain is already registered; sceneDesc must be before camera):
```swift
// Camera pipeline — required start order: brain → sceneDesc → camera
// brain must subscribe to SceneDescriptionEvent before sceneDesc starts publishing.
// sceneDesc must subscribe to CameraFrameEvent before camera starts publishing.
await sup.register(sceneDesc, restartPolicy: .onFailure(maxRetries: 3, backoff: 1), dependencies: [brain.id])
await sup.register(camera,    restartPolicy: .onFailure(maxRetries: 3, backoff: 2), dependencies: [sceneDesc.id])
```

- [ ] **Step 4: Build to confirm it compiles**

```bash
cd Banti && xcodebuild build -scheme Banti -destination 'platform=macOS' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`. If there are errors, they will be Swift compiler errors pointing to exact lines.

- [ ] **Step 5: Run full test suite**

```bash
cd Banti && xcodebuild test -scheme Banti -destination 'platform=macOS' 2>&1 | grep -E "(PASS|FAIL|error:)" | tail -30
```

Expected: all tests pass, no regressions.

- [ ] **Step 6: Commit**

```bash
git add Banti/Banti/BantiApp.swift
git commit -m "feat: wire camera + scene description actors into BantiApp pipeline"
```

---

## Done

The camera perception pipeline is complete:

- `CameraFrameActor` captures JPEG frames continuously → `CameraFrameEvent` on EventHub
- `SceneDescriptionActor` self-throttles → calls Claude vision API → `SceneDescriptionEvent` on EventHub
- `BrainActor` passively appends scene descriptions to `context.md`
- `VisionProvider` is fully extensible — add a new provider with one conformance + one switch case
- Any future analysis actor (emotion, face, body movement) follows the same pattern: subscribe to `CameraFrameEvent`, self-throttle, publish own event type — zero changes to the capture layer

**To verify end-to-end manually:** Build and run in Xcode, grant camera permission on first launch, check the macOS Console for `com.banti.scene-description` log messages confirming scene descriptions are published, and inspect `~/Library/Application Support/Banti/context.md` for `(scene)` lines.
