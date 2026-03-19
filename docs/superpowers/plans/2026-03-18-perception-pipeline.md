# Perception Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single Moondream model with a multi-modal perception pipeline: Apple Vision runs locally on every frame as a fast gate, selectively triggering Hume AI (emotions) and GPT-4o (activity, gesture, screen) as background cloud analyzers.

**Architecture:** `LocalPerception` (Apple Vision) processes every JPEG frame and emits `[PerceptionEvent]` to `PerceptionRouter` (actor). The router throttles and dispatches cloud analyzers as non-blocking `Task {}`. All results flow into `PerceptionContext` (actor) which logs a structured JSON snapshot every 2s. `CameraCapture` and `ScreenCapture` depend on the `FrameProcessor` protocol instead of the old `LocalVision`.

**Tech Stack:** Swift 5.9, Vision framework (macOS 14), Hume AI Expression Measurement API, OpenAI GPT-4o Vision API, XCTest

---

## File Map

### New directory: `Sources/BantiCore/` (library target)

All existing source files **except `main.swift`** move here. New files are added here too.

| File | Responsibility |
|---|---|
| `Sources/BantiCore/Logger.swift` | Moved unchanged |
| `Sources/BantiCore/Deduplicator.swift` | Moved unchanged |
| `Sources/BantiCore/AXReader.swift` | Moved unchanged |
| `Sources/BantiCore/CameraCapture.swift` | Moved, dependency swapped to `FrameProcessor` |
| `Sources/BantiCore/ScreenCapture.swift` | Moved, dependency swapped to `FrameProcessor` |
| `Sources/BantiCore/PerceptionTypes.swift` | **NEW** — all shared types, protocols, enums |
| `Sources/BantiCore/PerceptionContext.swift` | **NEW** — actor, state fields, snapshot timer |
| `Sources/BantiCore/LocalPerception.swift` | **NEW** — Apple Vision frame analysis, conforms to `FrameProcessor` |
| `Sources/BantiCore/PerceptionRouter.swift` | **NEW** — actor, throttle state, cloud dispatch |
| `Sources/BantiCore/HumeEmotionAnalyzer.swift` | **NEW** — face crop + Hume AI API call |
| `Sources/BantiCore/GPT4oActivityAnalyzer.swift` | **NEW** — full-frame GPT-4o activity description |
| `Sources/BantiCore/GPT4oGestureAnalyzer.swift` | **NEW** — keypoints + GPT-4o gesture interpretation |
| `Sources/BantiCore/GPT4oScreenAnalyzer.swift` | **NEW** — OCR text + GPT-4o text-only screen understanding |

### Existing: `Sources/banti/` (executable target, only `main.swift`)

| File | Change |
|---|---|
| `Sources/banti/main.swift` | Rewired to use new components |
| `Sources/banti/LocalVision.swift` | **Deleted** |

### Tests: `Tests/BantiTests/`

| File | What it tests |
|---|---|
| `Tests/BantiTests/PerceptionTypesTests.swift` | State struct init, `PerceptionObservation` enum |
| `Tests/BantiTests/PerceptionContextTests.swift` | State updates, snapshot JSON format |
| `Tests/BantiTests/PerceptionRouterTests.swift` | Throttle logic, routing conditions |
| `Tests/BantiTests/HumeEmotionAnalyzerTests.swift` | Y-flip face crop math |
| `Tests/BantiTests/GPT4oGestureAnalyzerTests.swift` | Keypoint serialization from events |

---

## Task 1: Restructure Package.swift — split into BantiCore library + banti executable

This enables `@testable import BantiCore` in tests. Without this split, unit testing is blocked by the `main.swift` entry point.

**Files:**
- Modify: `Package.swift`
- Create dir: `Sources/BantiCore/`
- Move (shell): all `.swift` files from `Sources/banti/` except `main.swift` → `Sources/BantiCore/`

- [ ] **Step 1: Update Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "banti",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "BantiCore",
            path: "Sources/BantiCore"
        ),
        .executableTarget(
            name: "banti",
            dependencies: ["BantiCore"],
            path: "Sources/banti"
        ),
        .testTarget(
            name: "BantiTests",
            dependencies: ["BantiCore"],
            path: "Tests/BantiTests"
        ),
    ]
)
```

- [ ] **Step 2: Move source files**

```bash
mkdir -p Sources/BantiCore
mv Sources/banti/Logger.swift Sources/BantiCore/
mv Sources/banti/Deduplicator.swift Sources/BantiCore/
mv Sources/banti/AXReader.swift Sources/BantiCore/
mv Sources/banti/CameraCapture.swift Sources/BantiCore/
mv Sources/banti/ScreenCapture.swift Sources/BantiCore/
mv Sources/banti/LocalVision.swift Sources/BantiCore/
# main.swift stays in Sources/banti/
```

- [ ] **Step 3: Verify build**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift build 2>&1
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/BantiCore/ Sources/banti/
git commit -m "refactor: split into BantiCore library + banti executable for testability"
```

---

## Task 2: PerceptionTypes.swift — all shared types and protocols

**Files:**
- Create: `Sources/BantiCore/PerceptionTypes.swift`
- Create: `Tests/BantiTests/PerceptionTypesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BantiTests/PerceptionTypesTests.swift
import XCTest
@testable import BantiCore

final class PerceptionTypesTests: XCTestCase {

    func testStateStructsAreInitializable() {
        let now = Date()
        let face = FaceState(boundingBox: .zero, landmarksDetected: true, updatedAt: now)
        XCTAssertTrue(face.landmarksDetected)

        let emotion = EmotionState(emotions: [("focused", 0.9)], updatedAt: now)
        XCTAssertEqual(emotion.emotions.first?.label, "focused")

        let pose = PoseState(bodyPoints: [:], handPoints: nil, updatedAt: now)
        XCTAssertNil(pose.handPoints)

        let gesture = GestureState(description: "arms crossed", updatedAt: now)
        XCTAssertEqual(gesture.description, "arms crossed")

        let screen = ScreenState(ocrLines: ["hello"], interpretation: "code editor", updatedAt: now)
        XCTAssertEqual(screen.ocrLines.count, 1)

        let activity = ActivityState(description: "typing", updatedAt: now)
        XCTAssertEqual(activity.description, "typing")
    }

    func testPerceptionObservationEnum() {
        let now = Date()
        let obs = PerceptionObservation.emotion(EmotionState(emotions: [], updatedAt: now))
        if case .emotion(let s) = obs {
            XCTAssertTrue(s.emotions.isEmpty)
        } else {
            XCTFail("wrong case")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter PerceptionTypesTests 2>&1
```

Expected: compile error — `FaceState`, `EmotionState` etc. not found.

- [ ] **Step 3: Implement PerceptionTypes.swift**

```swift
// Sources/BantiCore/PerceptionTypes.swift
import Foundation
import Vision
import CoreGraphics

// MARK: - Frame processor protocol (replaces LocalVision dependency in captures)

protocol FrameProcessor {
    func process(jpegData: Data, source: String)
}

// MARK: - Events emitted by LocalPerception after Apple Vision analysis

enum PerceptionEvent {
    case faceDetected(observation: VNFaceObservation)
    case bodyPoseDetected(observation: VNHumanBodyPoseObservation)
    case handPoseDetected(observation: VNHumanHandPoseObservation)
    case humanPresent
    case textRecognized(lines: [String])   // confidence >= 0.5, top-to-bottom
    case sceneClassified(labels: [(identifier: String, confidence: Float)])
    case nothingDetected
}

// MARK: - State types (one per modality, all Codable for snapshot logging)

struct FaceState: Codable {
    let boundingBox: CodableCGRect
    let landmarksDetected: Bool
    let updatedAt: Date

    init(boundingBox: CGRect, landmarksDetected: Bool, updatedAt: Date) {
        self.boundingBox = CodableCGRect(boundingBox)
        self.landmarksDetected = landmarksDetected
        self.updatedAt = updatedAt
    }
}

struct EmotionState: Codable {
    struct Emotion: Codable {
        let label: String
        let score: Float
    }
    let emotions: [Emotion]
    let updatedAt: Date

    init(emotions: [(label: String, score: Float)], updatedAt: Date) {
        self.emotions = emotions.map { Emotion(label: $0.label, score: $0.score) }
        self.updatedAt = updatedAt
    }
}

struct PoseState: Codable {
    let bodyPoints: [String: CodableCGPoint]
    let handPoints: [String: CodableCGPoint]?
    let updatedAt: Date

    init(bodyPoints: [String: CGPoint], handPoints: [String: CGPoint]?, updatedAt: Date) {
        self.bodyPoints = bodyPoints.mapValues { CodableCGPoint($0) }
        self.handPoints = handPoints?.mapValues { CodableCGPoint($0) }
        self.updatedAt = updatedAt
    }
}

struct GestureState: Codable {
    let description: String
    let updatedAt: Date
}

struct ScreenState: Codable {
    let ocrLines: [String]
    let interpretation: String
    let updatedAt: Date
}

struct ActivityState: Codable {
    let description: String
    let updatedAt: Date
}

// MARK: - Observation envelope (returned by all cloud analyzers)

enum PerceptionObservation {
    case face(FaceState)
    case pose(PoseState)
    case emotion(EmotionState)
    case activity(ActivityState)
    case gesture(GestureState)
    case screen(ScreenState)
}

// MARK: - Cloud analyzer protocol

protocol CloudAnalyzer {
    /// jpegData is nil for text-only analyzers (GPT4oScreenAnalyzer).
    /// Image-requiring analyzers return nil when jpegData is nil.
    func analyze(jpegData: Data?, events: [PerceptionEvent]) async -> PerceptionObservation?
}

// MARK: - Perception dispatcher protocol (breaks forward dependency between LocalPerception and PerceptionRouter)

protocol PerceptionDispatcher: AnyObject {
    func dispatch(jpegData: Data, source: String, events: [PerceptionEvent]) async
}

// MARK: - Codable helpers for CGRect / CGPoint

struct CodableCGRect: Codable {
    let x, y, width, height: Double
    init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; width = r.width; height = r.height }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct CodableCGPoint: Codable {
    let x, y: Double
    init(_ p: CGPoint) { x = p.x; y = p.y }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter PerceptionTypesTests 2>&1
```

Expected: `Test Suite 'PerceptionTypesTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/PerceptionTypes.swift Tests/BantiTests/PerceptionTypesTests.swift
git commit -m "feat: add PerceptionTypes — shared enums, state structs, protocols"
```

---

## Task 3: PerceptionContext.swift — actor, state updates, snapshot timer

**Files:**
- Create: `Sources/BantiCore/PerceptionContext.swift`
- Create: `Tests/BantiTests/PerceptionContextTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BantiTests/PerceptionContextTests.swift
import XCTest
@testable import BantiCore

final class PerceptionContextTests: XCTestCase {

    func testUpdateSetsCorrectField() async {
        let ctx = PerceptionContext()
        let now = Date()
        await ctx.update(.activity(ActivityState(description: "typing", updatedAt: now)))
        let activity = await ctx.activity
        XCTAssertEqual(activity?.description, "typing")
    }

    func testSnapshotContainsSetFields() async throws {
        let ctx = PerceptionContext()
        let now = Date()
        await ctx.update(.activity(ActivityState(description: "reading", updatedAt: now)))
        await ctx.update(.emotion(EmotionState(emotions: [("calm", 0.8)], updatedAt: now)))
        let json = await ctx.snapshotJSON()
        XCTAssertTrue(json.contains("reading"))
        XCTAssertTrue(json.contains("calm"))
    }

    func testSnapshotIsEmptyWhenNoStateSet() async throws {
        let ctx = PerceptionContext()
        let json = await ctx.snapshotJSON()
        XCTAssertEqual(json, "{}")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter PerceptionContextTests 2>&1
```

Expected: compile error — `PerceptionContext` not found.

- [ ] **Step 3: Implement PerceptionContext.swift**

```swift
// Sources/BantiCore/PerceptionContext.swift
import Foundation

actor PerceptionContext {
    var face:     FaceState?
    var emotion:  EmotionState?
    var pose:     PoseState?
    var gesture:  GestureState?
    var screen:   ScreenState?
    var activity: ActivityState?

    func update(_ observation: PerceptionObservation) {
        switch observation {
        case .face(let s):     face = s
        case .pose(let s):     pose = s
        case .emotion(let s):  emotion = s
        case .activity(let s): activity = s
        case .gesture(let s):  gesture = s
        case .screen(let s):   screen = s
        }
    }

    /// Serialize non-nil fields to a compact JSON string for logging.
    func snapshotJSON() -> String {
        var dict: [String: Any] = [:]
        if let f = face     { dict["face"]     = encodable(f) }
        if let e = emotion  { dict["emotion"]  = encodable(e) }
        if let p = pose     { dict["pose"]     = encodable(p) }
        if let g = gesture  { dict["gesture"]  = encodable(g) }
        if let s = screen   { dict["screen"]   = encodable(s) }
        if let a = activity { dict["activity"] = encodable(a) }
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    /// Called from main.swift after wiring. Timer fires every 2 seconds.
    nonisolated func startSnapshotTimer(logger: Logger) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let json = await self.snapshotJSON()
                if json != "{}" {
                    logger.log(source: "perception", message: json)
                }
            }
        }
    }

    // Encode any Codable value to a JSON-compatible dictionary
    private func encodable<T: Codable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return obj
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter PerceptionContextTests 2>&1
```

Expected: `Test Suite 'PerceptionContextTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/PerceptionContext.swift Tests/BantiTests/PerceptionContextTests.swift
git commit -m "feat: add PerceptionContext actor with state updates and snapshot timer"
```

---

## Task 4: LocalPerception.swift — Apple Vision frame analysis

No unit tests for Vision framework calls (requires real image data). Build verification confirms correctness.

**Files:**
- Create: `Sources/BantiCore/LocalPerception.swift`

- [ ] **Step 1: Implement LocalPerception.swift**

```swift
// Sources/BantiCore/LocalPerception.swift
import Vision
import Foundation

final class LocalPerception: FrameProcessor {
    private let dispatcher: PerceptionDispatcher   // protocol — no forward dependency on PerceptionRouter
    private let analysisQueue = DispatchQueue(label: "banti.vision", qos: .userInitiated)

    init(dispatcher: PerceptionDispatcher) {
        self.dispatcher = dispatcher
    }

    // FrameProcessor conformance — called from capture layer
    func process(jpegData: Data, source: String) {
        analysisQueue.async { [weak self] in
            self?.analyze(jpegData: jpegData, source: source)
        }
    }

    private func analyze(jpegData: Data, source: String) {
        let handler = VNImageRequestHandler(data: jpegData, options: [:])
        var events: [PerceptionEvent] = []

        if source == "camera" {
            events = analyzeCameraFrame(handler: handler)
        } else if source == "screen" {
            events = analyzeScreenFrame(handler: handler)
        }

        Task { [weak self] in
            await self?.dispatcher.dispatch(jpegData: jpegData, source: source, events: events)
        }
    }

    private func analyzeCameraFrame(handler: VNImageRequestHandler) -> [PerceptionEvent] {
        var events: [PerceptionEvent] = []

        // Face detection + landmarks
        let faceRequest = VNDetectFaceRectanglesRequest()
        let landmarkRequest = VNDetectFaceLandmarksRequest()
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()
        let sceneRequest = VNClassifyImageRequest()

        try? handler.perform([faceRequest, landmarkRequest, bodyRequest, handRequest, humanRequest, sceneRequest])

        // Prefer landmark observations (they include bounding boxes too)
        if let faces = landmarkRequest.results, let face = faces.first {
            events.append(.faceDetected(observation: face))
        } else if let humans = humanRequest.results, !humans.isEmpty {
            events.append(.humanPresent)
        }

        if let bodies = bodyRequest.results, let body = bodies.first {
            events.append(.bodyPoseDetected(observation: body))
        }

        if let hands = handRequest.results, let hand = hands.first {
            events.append(.handPoseDetected(observation: hand))
        }

        if let scene = sceneRequest.results, !scene.isEmpty {
            let labels = scene.prefix(5).map { (identifier: $0.identifier, confidence: $0.confidence) }
            events.append(.sceneClassified(labels: labels))
        }

        return events.isEmpty ? [.nothingDetected] : events
    }

    private func analyzeScreenFrame(handler: VNImageRequestHandler) -> [PerceptionEvent] {
        var events: [PerceptionEvent] = []

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        let sceneRequest = VNClassifyImageRequest()

        try? handler.perform([textRequest, sceneRequest])

        if let observations = textRequest.results {
            let lines = observations
                .filter { $0.topCandidates(1).first?.confidence ?? 0 >= 0.5 }
                .compactMap { $0.topCandidates(1).first?.string }
            if !lines.isEmpty {
                events.append(.textRecognized(lines: lines))
            }
        }

        if let scene = sceneRequest.results, !scene.isEmpty {
            let labels = scene.prefix(5).map { (identifier: $0.identifier, confidence: $0.confidence) }
            events.append(.sceneClassified(labels: labels))
        }

        return events.isEmpty ? [.nothingDetected] : events
    }
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift build 2>&1
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/BantiCore/LocalPerception.swift
git commit -m "feat: add LocalPerception — Apple Vision gate, camera and screen frame analysis"
```

---

## Task 5: HumeEmotionAnalyzer.swift — face crop with Y-flip + Hume AI

**Files:**
- Create: `Sources/BantiCore/HumeEmotionAnalyzer.swift`
- Create: `Tests/BantiTests/HumeEmotionAnalyzerTests.swift`

- [ ] **Step 1: Write the failing test (Y-flip math)**

```swift
// Tests/BantiTests/HumeEmotionAnalyzerTests.swift
import XCTest
import CoreGraphics
@testable import BantiCore

final class HumeEmotionAnalyzerTests: XCTestCase {

    func testYFlipConvertsVisionToImageCoordinates() {
        // Vision bounding box: bottom-left origin, normalized
        // Example: bottom 30% of image, left 20%, width 60%, height 40%
        let visionBox = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        let flipped = HumeEmotionAnalyzer.flipBoundingBox(visionBox)

        // Flipped Y = 1 - origin.y - height = 1 - 0.3 - 0.4 = 0.3
        XCTAssertEqual(flipped.origin.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(flipped.origin.y, 0.3, accuracy: 0.001)
        XCTAssertEqual(flipped.width,    0.6, accuracy: 0.001)
        XCTAssertEqual(flipped.height,   0.4, accuracy: 0.001)
    }

    func testYFlipTopFace() {
        // Face at top of image in Vision coords: y=0.7 (high y = near top in bottom-left origin)
        let visionBox = CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.25)
        let flipped = HumeEmotionAnalyzer.flipBoundingBox(visionBox)
        // flipped.y = 1 - 0.7 - 0.25 = 0.05 (near top in image/top-left coords)
        XCTAssertEqual(flipped.origin.y, 0.05, accuracy: 0.001)
    }

    func testAnalyzeReturnsNilWhenJpegDataIsNil() async {
        let logger = Logger()
        let analyzer = HumeEmotionAnalyzer(apiKey: "test", logger: logger)
        let result = await analyzer.analyze(jpegData: nil, events: [])
        XCTAssertNil(result)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter HumeEmotionAnalyzerTests 2>&1
```

Expected: compile error — `HumeEmotionAnalyzer` not found.

- [ ] **Step 3: Implement HumeEmotionAnalyzer.swift**

```swift
// Sources/BantiCore/HumeEmotionAnalyzer.swift
// Hume AI Expression Measurement API
// Docs: https://dev.hume.ai/reference/expression-measurement/batch
import Foundation
import Vision
import CoreGraphics
import ImageIO

final class HumeEmotionAnalyzer: CloudAnalyzer {
    private let apiKey: String
    private let logger: Logger
    private let session: URLSession

    init(apiKey: String, logger: Logger, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.logger = logger
        self.session = session
    }

    func analyze(jpegData: Data?, events: [PerceptionEvent]) async -> PerceptionObservation? {
        guard let jpegData else { return nil }

        // Extract face bounding box from events
        let faceObservation = events.compactMap { event -> VNFaceObservation? in
            if case .faceDetected(let obs) = event { return obs }
            return nil
        }.first

        // Crop to face if detected; otherwise send full image
        let imageData: Data
        if let obs = faceObservation {
            imageData = crop(jpegData: jpegData, visionBox: obs.boundingBox) ?? jpegData
        } else {
            imageData = jpegData
        }

        return await callHumeAPI(imageData: imageData)
    }

    /// Crop JPEG to face region. Vision bounding box is normalized, bottom-left origin.
    func crop(jpegData: Data, visionBox: CGRect) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // Flip Y axis: Vision uses bottom-left origin; CGImage uses top-left
        let flipped = HumeEmotionAnalyzer.flipBoundingBox(visionBox)

        // Scale normalized coords to pixel coords; clamp to image bounds
        var pixelBox = CGRect(
            x: flipped.origin.x * imageWidth,
            y: flipped.origin.y * imageHeight,
            width:  flipped.width  * imageWidth,
            height: flipped.height * imageHeight
        )
        pixelBox = pixelBox.intersection(CGRect(origin: .zero, size: CGSize(width: imageWidth, height: imageHeight)))
        guard !pixelBox.isNull, pixelBox.width > 0, pixelBox.height > 0 else { return nil }

        guard let cropped = cgImage.cropping(to: pixelBox) else { return nil }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cropped, [kCGImageDestinationLossyCompressionQuality as String: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    /// Flip Vision bounding box from bottom-left to top-left origin (normalized coordinates).
    static func flipBoundingBox(_ box: CGRect) -> CGRect {
        CGRect(
            x: box.origin.x,
            y: 1.0 - box.origin.y - box.height,
            width:  box.width,
            height: box.height
        )
    }

    private func callHumeAPI(imageData: Data) async -> PerceptionObservation? {
        // Hume AI streaming inference endpoint for face expression measurement
        // Reference: https://dev.hume.ai/reference
        guard let url = URL(string: "https://api.hume.ai/v0/stream/models") else { return nil }

        let body: [String: Any] = [
            "models": ["face": [:]],
            "data":   imageData.base64EncodedString()
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Hume-Api-Key")

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                logger.log(source: "hume", message: "[warn] HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            return parseResponse(data: data)
        } catch {
            logger.log(source: "hume", message: "[warn] \(error.localizedDescription)")
            return nil
        }
    }

    private func parseResponse(data: Data) -> PerceptionObservation? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let face = json["face"] as? [String: Any],
              let predictions = face["predictions"] as? [[String: Any]],
              let first = predictions.first,
              let emotions = first["emotions"] as? [[String: Any]] else { return nil }

        let top5 = emotions
            .compactMap { e -> (String, Float)? in
                guard let name = e["name"] as? String,
                      let score = e["score"] as? Double else { return nil }
                return (name, Float(score))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(5)

        let state = EmotionState(emotions: Array(top5), updatedAt: Date())
        return .emotion(state)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter HumeEmotionAnalyzerTests 2>&1
```

Expected: `Test Suite 'HumeEmotionAnalyzerTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/HumeEmotionAnalyzer.swift Tests/BantiTests/HumeEmotionAnalyzerTests.swift
git commit -m "feat: add HumeEmotionAnalyzer with Y-flip face crop and Hume AI API call"
```

---

## Task 6: GPT4oActivityAnalyzer.swift — full-frame activity description

**Files:**
- Create: `Sources/BantiCore/GPT4oActivityAnalyzer.swift`

- [ ] **Step 1: Implement GPT4oActivityAnalyzer.swift**

```swift
// Sources/BantiCore/GPT4oActivityAnalyzer.swift
import Foundation

final class GPT4oActivityAnalyzer: CloudAnalyzer {
    private let apiKey: String
    private let logger: Logger
    private let session: URLSession

    init(apiKey: String, logger: Logger, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.logger = logger
        self.session = session
    }

    func analyze(jpegData: Data?, events: [PerceptionEvent]) async -> PerceptionObservation? {
        guard let jpegData else { return nil }
        let base64 = jpegData.base64EncodedString()
        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": 100,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
                    ["type": "text", "text": "In 1-2 sentences, describe what this person is doing right now. Focus on their activity and intent, not appearance."]
                ]
            ]]
        ]
        return await callGPT4o(apiKey: apiKey, body: body, logger: logger, session: session).map {
            .activity(ActivityState(description: $0, updatedAt: Date()))
        }
    }
}

// Shared GPT-4o call helper used by activity, gesture, and screen analyzers.
// apiKey must be passed explicitly — do not read from environment here.
func callGPT4o(apiKey: String, body: [String: Any], logger: Logger, session: URLSession) async -> String? {
    guard let url = URL(string: "https://api.openai.com/v1/chat/completions"),
          let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.httpBody = bodyData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    do {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            logger.log(source: "gpt4o", message: "[warn] HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            return nil
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        logger.log(source: "gpt4o", message: "[warn] \(error.localizedDescription)")
        return nil
    }
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift build 2>&1
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/BantiCore/GPT4oActivityAnalyzer.swift
git commit -m "feat: add GPT4oActivityAnalyzer — full-frame activity description via gpt-4o"
```

---

## Task 7: GPT4oGestureAnalyzer.swift — keypoints + GPT-4o gesture interpretation

**Files:**
- Create: `Sources/BantiCore/GPT4oGestureAnalyzer.swift`
- Create: `Tests/BantiTests/GPT4oGestureAnalyzerTests.swift`

- [ ] **Step 1: Write the failing test (keypoint serialization)**

```swift
// Tests/BantiTests/GPT4oGestureAnalyzerTests.swift
import XCTest
@testable import BantiCore

final class GPT4oGestureAnalyzerTests: XCTestCase {

    func testAnalyzeReturnsNilWhenJpegDataIsNil() async {
        let logger = Logger()
        let analyzer = GPT4oGestureAnalyzer(apiKey: "test", logger: logger)
        let result = await analyzer.analyze(jpegData: nil, events: [])
        XCTAssertNil(result)
    }

    func testKeypointJSONFromEmptyEventsIsEmptyObject() {
        let json = GPT4oGestureAnalyzer.keypointJSON(from: [])
        XCTAssertEqual(json, "{}")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter GPT4oGestureAnalyzerTests 2>&1
```

Expected: compile error — `GPT4oGestureAnalyzer` not found.

- [ ] **Step 3: Implement GPT4oGestureAnalyzer.swift**

```swift
// Sources/BantiCore/GPT4oGestureAnalyzer.swift
import Foundation
import Vision

final class GPT4oGestureAnalyzer: CloudAnalyzer {
    private let apiKey: String
    private let logger: Logger
    private let session: URLSession

    init(apiKey: String, logger: Logger, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.logger = logger
        self.session = session
    }

    func analyze(jpegData: Data?, events: [PerceptionEvent]) async -> PerceptionObservation? {
        guard let jpegData else { return nil }
        let base64 = jpegData.base64EncodedString()
        let keypoints = GPT4oGestureAnalyzer.keypointJSON(from: events)

        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": 80,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
                    ["type": "text", "text": "Body keypoints (normalized 0-1 coordinates): \(keypoints)\n\nIn one sentence, describe the person's posture, gesture, or body language. Be specific (e.g. 'leaning forward, hands on keyboard' or 'arms crossed, head tilted')."]
                ]
            ]]
        ]
        return await callGPT4o(apiKey: apiKey, body: body, logger: logger, session: session).map {
            .gesture(GestureState(description: $0, updatedAt: Date()))
        }
    }

    /// Serialize body/hand keypoints from perception events to a compact JSON string.
    static func keypointJSON(from events: [PerceptionEvent]) -> String {
        var points: [String: [String: Double]] = [:]

        for event in events {
            if case .bodyPoseDetected(let obs) = event {
                let jointNames = VNHumanBodyPoseObservation.JointName.allJoints
                for joint in jointNames {
                    if let point = try? obs.recognizedPoint(joint), point.confidence > 0.3 {
                        points["body_\(joint.rawValue.rawValue)"] = ["x": Double(point.x), "y": Double(point.y)]
                    }
                }
            }
            if case .handPoseDetected(let obs) = event {
                let jointNames = VNHumanHandPoseObservation.JointName.allJoints
                for joint in jointNames {
                    if let point = try? obs.recognizedPoint(joint), point.confidence > 0.3 {
                        points["hand_\(joint.rawValue.rawValue)"] = ["x": Double(point.x), "y": Double(point.y)]
                    }
                }
            }
        }

        guard !points.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: points),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// Extend joint name enums to provide all known joints
extension VNHumanBodyPoseObservation.JointName {
    static var allJoints: [VNHumanBodyPoseObservation.JointName] {
        [.nose, .leftEye, .rightEye, .leftEar, .rightEar,
         .leftShoulder, .rightShoulder, .neck,
         .leftElbow, .rightElbow, .leftWrist, .rightWrist,
         .leftHip, .rightHip, .root,
         .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
    }
}

extension VNHumanHandPoseObservation.JointName {
    static var allJoints: [VNHumanHandPoseObservation.JointName] {
        [.wrist,
         .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
         .indexMCP, .indexPIP, .indexDIP, .indexTip,
         .middleMCP, .middlePIP, .middleDIP, .middleTip,
         .ringMCP, .ringPIP, .ringDIP, .ringTip,
         .littleMCP, .littlePIP, .littleDIP, .littleTip]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter GPT4oGestureAnalyzerTests 2>&1
```

Expected: `Test Suite 'GPT4oGestureAnalyzerTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/GPT4oGestureAnalyzer.swift Tests/BantiTests/GPT4oGestureAnalyzerTests.swift
git commit -m "feat: add GPT4oGestureAnalyzer with body/hand keypoint serialization"
```

---

## Task 8: GPT4oScreenAnalyzer.swift — OCR lines → GPT-4o text-only

**Files:**
- Create: `Sources/BantiCore/GPT4oScreenAnalyzer.swift`

- [ ] **Step 1: Implement GPT4oScreenAnalyzer.swift**

```swift
// Sources/BantiCore/GPT4oScreenAnalyzer.swift
import Foundation

final class GPT4oScreenAnalyzer: CloudAnalyzer {
    private let apiKey: String
    private let logger: Logger
    private let session: URLSession

    init(apiKey: String, logger: Logger, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.logger = logger
        self.session = session
    }

    func analyze(jpegData: Data?, events: [PerceptionEvent]) async -> PerceptionObservation? {
        // Screen analyzer is text-only — no image needed
        let ocrLines = events.compactMap { event -> [String]? in
            if case .textRecognized(let lines) = event { return lines }
            return nil
        }.flatMap { $0 }

        guard !ocrLines.isEmpty else { return nil }

        let ocrText = ocrLines.joined(separator: "\n")
        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": 80,
            "messages": [[
                "role": "user",
                "content": "The following text was read from a computer screen via OCR:\n\n\(ocrText)\n\nIn one sentence, describe what the user is reading or working on."
            ]]
        ]

        return await callGPT4o(apiKey: apiKey, body: body, logger: logger, session: session).map { description in
            .screen(ScreenState(ocrLines: ocrLines, interpretation: description, updatedAt: Date()))
        }
    }
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift build 2>&1
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/BantiCore/GPT4oScreenAnalyzer.swift
git commit -m "feat: add GPT4oScreenAnalyzer — text-only screen content understanding via gpt-4o"
```

---

## Task 9: PerceptionRouter.swift — actor with throttle and dispatch

**Files:**
- Create: `Sources/BantiCore/PerceptionRouter.swift`
- Create: `Tests/BantiTests/PerceptionRouterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/BantiTests/PerceptionRouterTests.swift
import XCTest
@testable import BantiCore

final class PerceptionRouterTests: XCTestCase {

    func testShouldFireReturnsTrueWhenNeverFired() async {
        let router = PerceptionRouter(context: PerceptionContext(), logger: Logger())
        let result = await router.shouldFire(analyzerName: "test", throttleSeconds: 2.0)
        XCTAssertTrue(result)
    }

    func testShouldFireReturnsFalseBeforeThrottleExpires() async {
        let router = PerceptionRouter(context: PerceptionContext(), logger: Logger())
        // Mark as just fired
        await router.markFired(analyzerName: "test")
        let result = await router.shouldFire(analyzerName: "test", throttleSeconds: 60.0)
        XCTAssertFalse(result)
    }

    func testShouldFireReturnsTrueAfterThrottleExpires() async {
        let router = PerceptionRouter(context: PerceptionContext(), logger: Logger())
        // Inject a last-fired time far in the past
        await router.setLastFired(analyzerName: "test", date: Date(timeIntervalSinceNow: -100))
        let result = await router.shouldFire(analyzerName: "test", throttleSeconds: 2.0)
        XCTAssertTrue(result)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter PerceptionRouterTests 2>&1
```

Expected: compile error — `PerceptionRouter` not found.

- [ ] **Step 3: Implement PerceptionRouter.swift**

```swift
// Sources/BantiCore/PerceptionRouter.swift
import Foundation
import Vision

actor PerceptionRouter: PerceptionDispatcher {
    private var lastFired: [String: Date] = [:]
    private let context: PerceptionContext
    private let logger: Logger
    private var hume:     HumeEmotionAnalyzer?
    private var activity: GPT4oActivityAnalyzer?
    private var gesture:  GPT4oGestureAnalyzer?
    private var screen:   GPT4oScreenAnalyzer?

    init(context: PerceptionContext, logger: Logger) {
        self.context = context
        self.logger = logger
    }

    /// Configure cloud analyzers from environment variables. Call from main.swift.
    func configure() {
        let env = ProcessInfo.processInfo.environment
        if let key = env["HUME_API_KEY"] {
            hume = HumeEmotionAnalyzer(apiKey: key, logger: logger)
        } else {
            logger.log(source: "system", message: "[warn] HUME_API_KEY missing — emotion analysis disabled")
        }
        if let key = env["OPENAI_API_KEY"] {
            activity = GPT4oActivityAnalyzer(apiKey: key, logger: logger)
            gesture  = GPT4oGestureAnalyzer(apiKey: key, logger: logger)
            screen   = GPT4oScreenAnalyzer(apiKey: key, logger: logger)
        } else {
            logger.log(source: "system", message: "[warn] OPENAI_API_KEY missing — activity, gesture, screen analysis disabled")
        }
    }

    /// Called by LocalPerception after each frame is analyzed.
    func dispatch(jpegData: Data, source: String, events: [PerceptionEvent]) async {
        // Update face and pose state directly from local detections (no cloud needed)
        for event in events {
            if case .faceDetected(let obs) = event {
                let state = FaceState(boundingBox: obs.boundingBox,
                                      landmarksDetected: obs.landmarks != nil,
                                      updatedAt: Date())
                await context.update(.face(state))
            }
            if case .bodyPoseDetected(let obs) = event {
                let bodyPoints = extractBodyPoints(obs)
                let state = PoseState(bodyPoints: bodyPoints, handPoints: nil, updatedAt: Date())
                await context.update(.pose(state))
            }
        }

        // Dispatch cloud analyzers (throttled, non-blocking)
        let hasFace   = events.contains { if case .faceDetected   = $0 { return true }; return false }
        let hasHuman  = events.contains { if case .humanPresent   = $0 { return true }; return false }
        let hasBody   = events.contains { if case .bodyPoseDetected = $0 { return true }; return false }
        let hasHand   = events.contains { if case .handPoseDetected = $0 { return true }; return false }
        let hasText   = events.contains { if case .textRecognized = $0 { return true }; return false }

        // Note: shouldFire/markFired are synchronous actor-isolated methods — no await needed within dispatch
        if hasFace, let analyzer = hume, shouldFire(analyzerName: "hume", throttleSeconds: 2) {
            markFired(analyzerName: "hume")
            Task { if let obs = await analyzer.analyze(jpegData: jpegData, events: events) { await self.context.update(obs) } }
        }

        if (hasFace || hasHuman) && source == "camera", let analyzer = activity,
           shouldFire(analyzerName: "activity", throttleSeconds: 5) {
            markFired(analyzerName: "activity")
            Task { if let obs = await analyzer.analyze(jpegData: jpegData, events: events) { await self.context.update(obs) } }
        }

        if (hasBody || hasHand), let analyzer = gesture, shouldFire(analyzerName: "gesture", throttleSeconds: 3) {
            markFired(analyzerName: "gesture")
            Task { if let obs = await analyzer.analyze(jpegData: jpegData, events: events) { await self.context.update(obs) } }
        }

        if hasText && source == "screen", let analyzer = screen, shouldFire(analyzerName: "screen", throttleSeconds: 4) {
            markFired(analyzerName: "screen")
            Task { if let obs = await analyzer.analyze(jpegData: nil, events: events) { await self.context.update(obs) } }
        }
    }

    // MARK: - Throttle helpers (internal for testability)

    func shouldFire(analyzerName: String, throttleSeconds: Double) -> Bool {
        guard let last = lastFired[analyzerName] else { return true }
        return Date().timeIntervalSince(last) >= throttleSeconds
    }

    func markFired(analyzerName: String) {
        lastFired[analyzerName] = Date()
    }

    func setLastFired(analyzerName: String, date: Date) {
        lastFired[analyzerName] = date
    }

    // MARK: - Keypoint extraction helpers

    private func extractBodyPoints(_ obs: VNHumanBodyPoseObservation) -> [String: CGPoint] {
        var points: [String: CGPoint] = [:]
        for joint in VNHumanBodyPoseObservation.JointName.allJoints {
            if let p = try? obs.recognizedPoint(joint), p.confidence > 0.3 {
                points[joint.rawValue.rawValue] = CGPoint(x: p.x, y: p.y)
            }
        }
        return points
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift test --filter PerceptionRouterTests 2>&1
```

Expected: `Test Suite 'PerceptionRouterTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/PerceptionRouter.swift Tests/BantiTests/PerceptionRouterTests.swift
git commit -m "feat: add PerceptionRouter actor with throttle logic and cloud dispatch"
```

---

## Task 10: Update captures + main.swift + delete LocalVision.swift — final wiring

All wiring changes land in one commit so the build is never left broken.

**Files:**
- Modify: `Sources/BantiCore/CameraCapture.swift`
- Modify: `Sources/BantiCore/ScreenCapture.swift`
- Modify: `Sources/banti/main.swift`
- Delete: `Sources/BantiCore/LocalVision.swift`

- [ ] **Step 1: Update CameraCapture.swift**

Replace the `vision: LocalVision` property and init parameter with `frameProcessor: FrameProcessor`:

In `CameraCapture.swift`:
1. Change `private let vision: LocalVision` → `private let frameProcessor: FrameProcessor`
2. Change `init(logger: Logger, deduplicator: Deduplicator, vision: LocalVision)` → `init(logger: Logger, deduplicator: Deduplicator, frameProcessor: FrameProcessor)`
3. Change `vision.analyze(jpegData: jpegData, source: "camera")` → `frameProcessor.process(jpegData: jpegData, source: "camera")`

- [ ] **Step 2: Update ScreenCapture.swift**

Same substitution in `ScreenCapture.swift`:
1. Change `private let vision: LocalVision` → `private let frameProcessor: FrameProcessor`
2. Change init parameter: `vision: LocalVision` → `frameProcessor: FrameProcessor`
3. Change call site: `vision.analyze(...)` → `frameProcessor.process(...)`

- [ ] **Step 3: Rewrite main.swift**

**Files:**
- Modify: `Sources/banti/main.swift`
- Delete: `Sources/BantiCore/LocalVision.swift`

- [ ] **Step 4: Rewrite main.swift**

```swift
// Sources/banti/main.swift
import Foundation
import AppKit
import BantiCore

// Shared infrastructure
let logger = Logger()

logger.log(source: "system", message: "banti starting...")

// Perception pipeline
let context = PerceptionContext()
let router  = PerceptionRouter(context: context, logger: logger)

// Configure cloud analyzers from environment variables
Task { await router.configure() }

let localPerception = LocalPerception(dispatcher: router)

// Start snapshot logging (every 2s)
context.startSnapshotTimer(logger: logger)

// Start AX reader (accessibility side-channel)
let axReader = AXReader(logger: logger)
axReader.start()

// Start camera capture
let deduplicator = Deduplicator()
let cameraCapture = CameraCapture(logger: logger, deduplicator: deduplicator, frameProcessor: localPerception)
cameraCapture.start()

// Start screen capture (async)
let screenDeduplicator = Deduplicator()
let screenCapture = ScreenCapture(logger: logger, deduplicator: screenDeduplicator, frameProcessor: localPerception)
Task {
    await screenCapture.start()
}

logger.log(source: "system", message: "banti running. Press Ctrl+C to stop.")
RunLoop.main.run()
```

- [ ] **Step 5: Delete LocalVision.swift**

```bash
rm Sources/BantiCore/LocalVision.swift
```

- [ ] **Step 6: Full build + all tests pass**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && swift build 2>&1 && swift test 2>&1
```

Expected:
- `Build complete!`
- All tests pass

- [ ] **Step 7: Smoke test — run banti and verify [source: perception] lines appear**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti && make run &
sleep 10
# Should see [source: perception] JSON lines after ~2s
# Should see [source: ax] lines on window focus change
# Should NOT see any [source: moondream] or LocalVision references
kill %1
```

- [ ] **Step 8: Commit everything together**

```bash
git add Sources/BantiCore/CameraCapture.swift Sources/BantiCore/ScreenCapture.swift Sources/banti/main.swift
git rm Sources/BantiCore/LocalVision.swift
git commit -m "feat: wire perception pipeline — swap captures to FrameProcessor, rewire main.swift, remove LocalVision"
```

---

## Verification Checklist

After all tasks complete:

- [ ] `swift build` produces no warnings related to the new pipeline
- [ ] `swift test` passes all tests
- [ ] Running the app shows `[source: perception]` JSON snapshot logs every ~2s
- [ ] `[source: ax]` still fires on window focus changes (AXReader untouched)
- [ ] When `HUME_API_KEY` is unset, startup log shows `[warn] HUME_API_KEY missing`
- [ ] When `OPENAI_API_KEY` is unset, startup log shows `[warn] OPENAI_API_KEY missing`
- [ ] Apple Vision runs on every non-duplicate frame (even without API keys)
- [ ] No reference to `LocalVision` or `Moondream` anywhere in the codebase

---

## Setting API Keys

```bash
export HUME_API_KEY=your_key_here
export OPENAI_API_KEY=your_key_here
make run
```

Or add to `~/.zshrc` for persistence.
