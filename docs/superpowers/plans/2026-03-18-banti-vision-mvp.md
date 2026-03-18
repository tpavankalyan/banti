# Banti Vision MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS CLI-in-app-bundle that continuously captures screen and camera frames, reads the accessibility tree, deduplicates frames with dHash, passes changed frames to a local Moondream2 vision model via Ollama, and logs structured output to stdout.

**Architecture:** Six focused Swift source files (Logger, Deduplicator, LocalVision, AXReader, CameraCapture, ScreenCapture) wired together in main.swift. Each component is independently constructable and testable. Components that cannot produce hardware output (Logger, Deduplicator, LocalVision) are fully unit-tested with injectable dependencies; hardware components (AXReader, CameraCapture, ScreenCapture) are manually verified.

**Tech Stack:** Swift 5.9+, macOS 14+, ScreenCaptureKit, AVFoundation, AXUIElement, XCTest, URLSession (with URLProtocol stubbing for tests), Swift Package Manager, Ollama (moondream model)

---

## File Map

| File | Responsibility |
|---|---|
| `Package.swift` | SPM manifest — one executable target, one test target |
| `Info.plist` | Bundle ID + TCC permission usage strings |
| `Makefile` | Build executable and assemble `Banti.app` bundle |
| `Sources/banti/main.swift` | Entry point — permission checks, component wiring, run loop |
| `Sources/banti/Logger.swift` | Serial-queue stdout logger with ISO8601 timestamps |
| `Sources/banti/Deduplicator.swift` | dHash computation and per-source frame deduplication |
| `Sources/banti/LocalVision.swift` | Ollama HTTP client with availability check, timeouts, semaphore |
| `Sources/banti/AXReader.swift` | Accessibility tree observer and summariser |
| `Sources/banti/CameraCapture.swift` | AVCaptureSession 1fps camera capture |
| `Sources/banti/ScreenCapture.swift` | SCStream 1fps screen capture |
| `Tests/BantiTests/LoggerTests.swift` | Logger format and queue-safety tests |
| `Tests/BantiTests/DeduplicatorTests.swift` | dHash algorithm and deduplication logic tests |
| `Tests/BantiTests/LocalVisionTests.swift` | Ollama client with URLProtocol stub |

---

## Prerequisites

Before starting, verify these are installed on the machine:

```bash
xcode-select --install          # Xcode command-line tools
brew install ollama
ollama pull moondream
ollama serve &                  # keep running in a separate terminal
```

> **Hardware requirement:** Apple Silicon (M1 or later) is required. On Intel Macs, Moondream2 inference takes 8–15s, which will exceed the 5s timeout on non-first requests — frames will silently time out and only `[warn] inference timeout` entries will appear.

---

## Task 1: Project Scaffold

**Files:**
- Create: `Package.swift`
- Create: `Info.plist`
- Create: `Makefile`
- Create: `Sources/banti/main.swift` (stub)
- Create: `Tests/BantiTests/BantiTests.swift` (stub)

- [ ] **Step 1: Create Package.swift**

```swift
// Package.swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "banti",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "banti",
            path: "Sources/banti"
        ),
        .testTarget(
            name: "BantiTests",
            dependencies: ["banti"],
            path: "Tests/BantiTests"
        ),
    ]
)
```

- [ ] **Step 2: Create Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.banti.app</string>
    <key>CFBundleName</key>
    <string>Banti</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Banti needs screen access to understand what you are doing.</string>
    <key>NSCameraUsageDescription</key>
    <string>Banti needs camera access to see you.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Banti will use the microphone in a future version.</string>
</dict>
</plist>
```

- [ ] **Step 3: Create Makefile**

```makefile
APP = Banti.app
BINARY = .build/debug/banti
BUNDLE_BINARY = $(APP)/Contents/MacOS/banti

build:
	swift build
	mkdir -p $(APP)/Contents/MacOS
	cp $(BINARY) $(BUNDLE_BINARY)
	cp Info.plist $(APP)/Contents/Info.plist

run: build
	./$(BUNDLE_BINARY)

test:
	swift test

clean:
	rm -rf .build $(APP)

.PHONY: build run test clean
```

- [ ] **Step 4: Create stub Sources/banti/main.swift**

```swift
// main.swift
import Foundation
print("banti starting...")
RunLoop.main.run()
```

- [ ] **Step 5: Create stub Tests/BantiTests/BantiTests.swift**

```swift
import XCTest

final class BantiTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 6: Verify it builds and tests pass**

```bash
swift build
swift test
```

Expected: build succeeds, 1 test passes.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Info.plist Makefile Sources/ Tests/
git commit -m "feat: scaffold Swift package with app bundle structure"
```

---

## Task 2: Logger

**Files:**
- Create: `Sources/banti/Logger.swift`
- Create: `Tests/BantiTests/LoggerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/LoggerTests.swift
import XCTest
@testable import banti

final class LoggerTests: XCTestCase {

    func testLogFormatsCorrectly() {
        var output: [String] = []
        let logger = Logger { line in output.append(line) }

        logger.log(source: "screen", message: "user is coding")

        // Give the serial queue time to flush
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(output.count, 1)
        let line = output[0]
        XCTAssertTrue(line.contains("[source: screen]"), "Missing source tag: \(line)")
        XCTAssertTrue(line.contains("user is coding"), "Missing message: \(line)")
        // ISO8601 format: starts with year
        XCTAssertTrue(line.hasPrefix("[20"), "Missing ISO8601 timestamp: \(line)")
    }

    func testLogSourceVariants() {
        var output: [String] = []
        let logger = Logger { line in output.append(line) }

        logger.log(source: "camera", message: "face detected")
        logger.log(source: "ax", message: "xcode focused")
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(output.count, 2)
        XCTAssertTrue(output[0].contains("[source: camera]"))
        XCTAssertTrue(output[1].contains("[source: ax]"))
    }

    func testLogIsQueueSafe() {
        var output: [String] = []
        let lock = NSLock()
        let logger = Logger { line in
            lock.lock()
            output.append(line)
            lock.unlock()
        }

        let group = DispatchGroup()
        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                logger.log(source: "screen", message: "msg \(i)")
                group.leave()
            }
        }
        group.wait()
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(output.count, 20)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter LoggerTests
```

Expected: FAIL — `Logger` type not found.

- [ ] **Step 3: Implement Logger**

```swift
// Sources/banti/Logger.swift
import Foundation

final class Logger {
    private let queue = DispatchQueue(label: "banti.logger")
    private let output: (String) -> Void
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(output: @escaping (String) -> Void = { print($0) }) {
        self.output = output
    }

    func log(source: String, message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = self.formatter.string(from: Date())
            self.output("[\(timestamp)] [source: \(source)] \(message)")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter LoggerTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/banti/Logger.swift Tests/BantiTests/LoggerTests.swift
git commit -m "feat: add Logger with ISO8601 timestamps and serial queue"
```

---

## Task 3: Deduplicator

**Files:**
- Create: `Sources/banti/Deduplicator.swift`
- Create: `Tests/BantiTests/DeduplicatorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/DeduplicatorTests.swift
import XCTest
@testable import banti

final class DeduplicatorTests: XCTestCase {

    // dHash: 9x8 grayscale → compare adjacent columns → 64-bit hash
    func testDHashIdenticalPixelsProducesZero() {
        // All-white 9x8 image: all adjacent pairs identical → all bits 0
        let pixels = [UInt8](repeating: 255, count: 9 * 8)
        let hash = Deduplicator.dHash(pixels: pixels, width: 9, height: 8)
        XCTAssertEqual(hash, 0)
    }

    func testDHashAlternatingPixelsProducesNonZero() {
        // Alternating black/white columns: every adjacent pair differs → all bits 1
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        for row in 0..<8 {
            for col in 0..<9 {
                pixels[row * 9 + col] = col % 2 == 0 ? 0 : 255
            }
        }
        let hash = Deduplicator.dHash(pixels: pixels, width: 9, height: 8)
        XCTAssertEqual(hash, UInt64.max)
    }

    func testHammingDistance() {
        XCTAssertEqual(Deduplicator.hammingDistance(0b0000, 0b0000), 0)
        XCTAssertEqual(Deduplicator.hammingDistance(0b1111, 0b0000), 4)
        XCTAssertEqual(Deduplicator.hammingDistance(UInt64.max, 0), 64)
    }

    func testIsNewReturnsTrueForFirstFrame() {
        var dedup = Deduplicator()
        let pixels = [UInt8](repeating: 128, count: 9 * 8)
        XCTAssertTrue(dedup.isNew(pixels: pixels, width: 9, height: 8, source: "screen"))
    }

    func testIsNewReturnsFalseForIdenticalFrame() {
        var dedup = Deduplicator()
        let pixels = [UInt8](repeating: 128, count: 9 * 8)
        _ = dedup.isNew(pixels: pixels, width: 9, height: 8, source: "screen")
        XCTAssertFalse(dedup.isNew(pixels: pixels, width: 9, height: 8, source: "screen"))
    }

    func testIsNewReturnsTrueForChangedFrame() {
        var dedup = Deduplicator()
        let pixels1 = [UInt8](repeating: 0, count: 9 * 8)
        var pixels2 = [UInt8](repeating: 0, count: 9 * 8)
        pixels2[0] = 255; pixels2[1] = 0  // one difference → 1 bit flip

        _ = dedup.isNew(pixels: pixels1, width: 9, height: 8, source: "screen")
        XCTAssertTrue(dedup.isNew(pixels: pixels2, width: 9, height: 8, source: "screen"))
    }

    func testSourcesTrackedIndependently() {
        var dedup = Deduplicator()
        let pixels = [UInt8](repeating: 200, count: 9 * 8)

        _ = dedup.isNew(pixels: pixels, width: 9, height: 8, source: "screen")
        // camera has never seen this hash — should be new
        XCTAssertTrue(dedup.isNew(pixels: pixels, width: 9, height: 8, source: "camera"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter DeduplicatorTests
```

Expected: FAIL — `Deduplicator` not found.

- [ ] **Step 3: Implement Deduplicator**

```swift
// Sources/banti/Deduplicator.swift
import Foundation
import CoreVideo
import Accelerate

struct Deduplicator {
    private var lastHashes: [String: UInt64] = [:]
    private let threshold = 10  // Hamming distance ≤ 10 → duplicate

    // Returns true if the frame should be processed (is meaningfully new)
    mutating func isNew(pixels: [UInt8], width: Int, height: Int, source: String) -> Bool {
        let hash = Deduplicator.dHash(pixels: pixels, width: width, height: height)
        if let last = lastHashes[source], Deduplicator.hammingDistance(hash, last) <= threshold {
            return false
        }
        lastHashes[source] = hash
        return true
    }

    // Convenience entry point for CVPixelBuffer — downscales to 9x8 grayscale first
    mutating func isNew(pixelBuffer: CVPixelBuffer, source: String) -> Bool {
        guard let pixels = Deduplicator.toGrayscale9x8(pixelBuffer) else { return true }
        return isNew(pixels: pixels, width: 9, height: 8, source: source)
    }

    // dHash: compare adjacent horizontal pixel pairs, 8 comparisons × 8 rows = 64 bits
    static func dHash(pixels: [UInt8], width: Int, height: Int) -> UInt64 {
        precondition(width == 9 && height == 8, "dHash requires 9x8 input")
        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let left = pixels[row * 9 + col]
                let right = pixels[row * 9 + col + 1]
                if left < right {
                    hash |= (1 << UInt64(row * 8 + col))
                }
            }
        }
        return hash
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    // Downscale CVPixelBuffer to 9x8 grayscale using vImage
    static func toGrayscale9x8(_ buffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let srcWidth = CVPixelBufferGetWidth(buffer)
        let srcHeight = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)

        // Convert BGRA/RGBA to grayscale using luma coefficients
        var gray = [UInt8](repeating: 0, count: srcWidth * srcHeight)
        let srcData = base.assumingMemoryBound(to: UInt8.self)

        if pixelFormat == kCVPixelFormatType_32BGRA {
            for i in 0..<(srcWidth * srcHeight) {
                let row = i / srcWidth
                let col = i % srcWidth
                let offset = row * bytesPerRow + col * 4
                let b = Float(srcData[offset])
                let g = Float(srcData[offset + 1])
                let r = Float(srcData[offset + 2])
                gray[i] = UInt8(0.299 * r + 0.587 * g + 0.114 * b)
            }
        } else {
            // Fallback: treat first channel as luma
            for i in 0..<(srcWidth * srcHeight) {
                let row = i / srcWidth
                let col = i % srcWidth
                gray[i] = srcData[row * bytesPerRow + col * 4]
            }
        }

        // Downscale to 9x8 using nearest-neighbour
        var result = [UInt8](repeating: 0, count: 9 * 8)
        for row in 0..<8 {
            for col in 0..<9 {
                let srcRow = row * srcHeight / 8
                let srcCol = col * srcWidth / 9
                result[row * 9 + col] = gray[srcRow * srcWidth + srcCol]
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter DeduplicatorTests
```

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/banti/Deduplicator.swift Tests/BantiTests/DeduplicatorTests.swift
git commit -m "feat: add Deduplicator with dHash and per-source frame deduplication"
```

---

## Task 4: LocalVision

**Files:**
- Create: `Sources/banti/LocalVision.swift`
- Create: `Tests/BantiTests/LocalVisionTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/LocalVisionTests.swift
import XCTest
@testable import banti

// URLProtocol stub to intercept Ollama HTTP calls without a real server
final class MockOllamaProtocol: URLProtocol {
    static var responseData: Data = Data()
    static var responseStatusCode: Int = 200
    static var requestsReceived: [[String: Any]] = []
    static var shouldFail = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if MockOllamaProtocol.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.connectionRefused))
            return
        }
        // Capture request body for assertions
        if let body = request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            MockOllamaProtocol.requestsReceived.append(json)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: MockOllamaProtocol.responseStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: MockOllamaProtocol.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LocalVisionTests: XCTestCase {
    var session: URLSession!
    var logger: Logger!
    var logs: [String]!

    override func setUp() {
        super.setUp()
        MockOllamaProtocol.responseData = Data()
        MockOllamaProtocol.responseStatusCode = 200
        MockOllamaProtocol.requestsReceived = []
        MockOllamaProtocol.shouldFail = false

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockOllamaProtocol.self]
        session = URLSession(configuration: config)

        logs = []
        logger = Logger { [weak self] line in self?.logs.append(line) }
    }

    func testAvailabilityCheckSuccess() {
        MockOllamaProtocol.responseData = #"{"models":[]}"#.data(using: .utf8)!
        let vision = LocalVision(session: session, logger: logger)

        let expectation = XCTestExpectation(description: "check completes")
        vision.checkAvailability {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertTrue(vision.isAvailable)
    }

    func testAvailabilityCheckFailure() {
        MockOllamaProtocol.shouldFail = true
        let vision = LocalVision(session: session, logger: logger)

        let expectation = XCTestExpectation(description: "check completes")
        vision.checkAvailability {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertFalse(vision.isAvailable)

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(logs.contains(where: { $0.contains("Ollama not running") }))
    }

    func testAnalyzeIncludesModelAndPrompt() {
        let responseJSON = #"{"response":"a person typing on a keyboard"}"#
        MockOllamaProtocol.responseData = responseJSON.data(using: .utf8)!
        let vision = LocalVision(session: session, logger: logger)
        vision.isAvailable = true
        vision.isFirstRequest = false

        let jpegData = Data([0xFF, 0xD8, 0xFF])  // minimal JPEG header stub
        let expectation = XCTestExpectation(description: "analyze completes")
        vision.analyze(jpegData: jpegData, source: "screen") {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(MockOllamaProtocol.requestsReceived.count, 1)
        let body = MockOllamaProtocol.requestsReceived[0]
        XCTAssertEqual(body["model"] as? String, "moondream")
        XCTAssertNotNil(body["prompt"])

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(logs.contains(where: { $0.contains("[source: screen]") && $0.contains("person typing") }))
    }

    func testAnalyzeSkipsWhenUnavailable() {
        let vision = LocalVision(session: session, logger: logger)
        vision.isAvailable = false

        let jpegData = Data([0xFF, 0xD8, 0xFF])
        let expectation = XCTestExpectation(description: "analyze skips quickly")
        vision.analyze(jpegData: jpegData, source: "screen") {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(MockOllamaProtocol.requestsReceived.count, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter LocalVisionTests
```

Expected: FAIL — `LocalVision` not found.

- [ ] **Step 3: Implement LocalVision**

```swift
// Sources/banti/LocalVision.swift
import Foundation

final class LocalVision {
    private let session: URLSession
    private let logger: Logger
    private let semaphore = DispatchSemaphore(value: 2)
    private let inferenceQueue = DispatchQueue(label: "banti.inference", attributes: .concurrent)
    private let baseURL = "http://localhost:11434"

    var isAvailable: Bool = false
    var isFirstRequest: Bool = true

    init(session: URLSession = .shared, logger: Logger) {
        self.session = session
        self.logger = logger
    }

    // Check if Ollama is reachable. Calls completion when done.
    func checkAvailability(completion: (() -> Void)? = nil) {
        guard let url = URL(string: "\(baseURL)/api/tags") else { completion?(); return }
        let task = session.dataTask(with: url) { [weak self] _, response, error in
            guard let self else { return }
            if error != nil || (response as? HTTPURLResponse)?.statusCode != 200 {
                self.isAvailable = false
                self.logger.log(source: "system", message: "[error] Ollama not running at \(self.baseURL) — vision inference disabled")
            } else {
                self.isAvailable = true
                self.isFirstRequest = true  // reset cold-start flag on reconnect
            }
            completion?()
        }
        task.resume()
    }

    // Start periodic availability recheck every 30 seconds
    func startRecheckTimer() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.checkAvailability()
            self?.startRecheckTimer()
        }
    }

    // Analyze a JPEG frame from the given source
    func analyze(jpegData: Data, source: String, completion: (() -> Void)? = nil) {
        guard isAvailable else { completion?(); return }
        guard semaphore.wait(timeout: .now()) == .success else {
            completion?()
            return  // inference queue full, drop this frame
        }

        inferenceQueue.async { [weak self] in
            defer {
                self?.semaphore.signal()
                completion?()
            }
            self?.sendRequest(jpegData: jpegData, source: source)
        }
    }

    private func sendRequest(jpegData: Data, source: String) {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return }

        let timeout = isFirstRequest ? 15.0 : 5.0
        isFirstRequest = false

        let base64Image = jpegData.base64EncodedString()
        let body: [String: Any] = [
            "model": "moondream",
            "prompt": "Describe what you see concisely. Focus on what the user is doing.",
            "images": [base64Image],
            "stream": false
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { [weak self] data, _, error in
            defer { semaphore.signal() }
            if error != nil {
                self?.logger.log(source: source, message: "[warn] inference timeout (source: \(source))")
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? String else { return }
            self?.logger.log(source: source, message: response.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        task.resume()
        semaphore.wait()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter LocalVisionTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/banti/LocalVision.swift Tests/BantiTests/LocalVisionTests.swift
git commit -m "feat: add LocalVision Ollama client with availability check and semaphore"
```

---

## Task 5: AXReader

**Files:**
- Create: `Sources/banti/AXReader.swift`

> No unit tests — AXUIElement APIs require a running process with real permissions and cannot be meaningfully stubbed. Verified manually in Task 8.

- [ ] **Step 1: Implement AXReader**

```swift
// Sources/banti/AXReader.swift
import ApplicationServices
import Foundation

final class AXReader {
    private let logger: Logger
    private var observer: AXObserver?
    private var currentApp: AXUIElement?

    init(logger: Logger) {
        self.logger = logger
    }

    // Returns false if permission is not granted
    @discardableResult
    func start() -> Bool {
        guard AXIsProcessTrusted() else {
            logger.log(source: "system", message: "[error] Accessibility permission not granted — AX reader disabled")
            return false
        }
        setupObserver()
        return true
    }

    private func setupObserver() {
        // Use PID 0 to create a system-wide observer capable of observing all apps
        var obs: AXObserver?
        AXObserverCreate(0, { _, _, _, userData in
            guard let ptr = userData else { return }
            let reader = Unmanaged<AXReader>.fromOpaque(ptr).takeUnretainedValue()
            reader.onFocusChange()
        }, &obs)

        guard let obs else { return }
        observer = obs

        let notifications = [
            kAXFocusedWindowChangedNotification,
            kAXApplicationActivatedNotification
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let systemWide = AXUIElementCreateSystemWide()

        for notification in notifications {
            AXObserverAddNotification(obs, systemWide, notification as CFString, selfPtr)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        onFocusChange()  // capture initial state
    }

    private func onFocusChange() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        guard let app = focusedApp else { return }

        var appName: CFTypeRef?
        AXUIElementCopyAttributeValue(app as! AXUIElement, kAXTitleAttribute as CFString, &appName)

        var focusedWindow: CFTypeRef?
        AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        var windowTitle = "unknown window"
        if let window = focusedWindow {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
            if let t = title as? String { windowTitle = t }
        }

        var elements: [String] = []
        if let window = focusedWindow {
            walk(element: window as! AXUIElement, depth: 0, maxDepth: 3, maxElements: 50, results: &elements)
        }

        let summary = [
            "app: \(appName as? String ?? "unknown")",
            "window: \(windowTitle)",
            elements.isEmpty ? nil : "elements: \(elements.joined(separator: " | "))"
        ].compactMap { $0 }.joined(separator: ", ")

        logger.log(source: "ax", message: summary)
    }

    private func walk(element: AXUIElement, depth: Int, maxDepth: Int, maxElements: Int, results: inout [String]) {
        guard depth < maxDepth, results.count < maxElements else { return }

        var role: CFTypeRef?
        var title: CFTypeRef?
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)

        let parts = [role as? String, title as? String, value as? String].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            results.append(parts.joined(separator: ":"))
        }

        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard let childList = children as? [AXUIElement] else { return }
        for child in childList {
            walk(element: child, depth: depth + 1, maxDepth: maxDepth, maxElements: maxElements, results: &results)
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/banti/AXReader.swift
git commit -m "feat: add AXReader with bounded tree walk and graceful permission handling"
```

---

## Task 6: CameraCapture

**Files:**
- Create: `Sources/banti/CameraCapture.swift`

> No unit tests — AVCaptureSession requires real hardware. Verified manually in Task 8.

- [ ] **Step 1: Implement CameraCapture**

```swift
// Sources/banti/CameraCapture.swift
import AVFoundation
import Foundation

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let logger: Logger
    private var deduplicator: Deduplicator  // var: struct state must persist across callbacks
    private let vision: LocalVision
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "banti.camera", qos: .userInitiated)
    private var lastFrameTime: CMTime = .zero

    init(logger: Logger, deduplicator: Deduplicator, vision: LocalVision) {
        self.logger = logger
        self.deduplicator = deduplicator
        self.vision = vision
    }

    // Request permission and start capture if granted
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if granted {
                self.configureAndStart()
            } else {
                self.logger.log(source: "system", message: "[error] Camera permission denied — camera capture disabled")
            }
        }
    }

    private func configureAndStart() {
        let session = AVCaptureSession()
        session.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            logger.log(source: "system", message: "[error] No front camera available")
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        output.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        self.session = session
        session.startRunning()
    }

    // AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // Throttle to 1fps
        guard CMTimeSubtract(presentationTime, lastFrameTime).seconds >= 1.0 else { return }
        lastFrameTime = presentationTime

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // deduplicator is a struct — mutate self.deduplicator directly so state persists
        guard deduplicator.isNew(pixelBuffer: pixelBuffer, source: "camera") else { return }

        // Encode to JPEG synchronously before buffer is released
        guard let jpegData = jpegData(from: pixelBuffer) else { return }
        vision.analyze(jpegData: jpegData, source: "camera")
    }

    private func jpegData(from buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        return context.jpegRepresentation(of: ciImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/banti/CameraCapture.swift
git commit -m "feat: add CameraCapture with 1fps throttle and permission handling"
```

---

## Task 7: ScreenCapture

**Files:**
- Create: `Sources/banti/ScreenCapture.swift`

> No unit tests — SCStream requires real screen recording permission. Verified manually in Task 8.

- [ ] **Step 1: Implement ScreenCapture**

```swift
// Sources/banti/ScreenCapture.swift
import ScreenCaptureKit
import Foundation
import CoreImage

final class ScreenCapture: NSObject, SCStreamOutput {
    private let logger: Logger
    private var deduplicator: Deduplicator  // var: struct state must persist across callbacks
    private let vision: LocalVision
    private var stream: SCStream?
    private var lastFrameTime: CMTime = .zero

    init(logger: Logger, deduplicator: Deduplicator, vision: LocalVision) {
        self.logger = logger
        self.deduplicator = deduplicator
        self.vision = vision
    }

    func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = primaryDisplay(from: content) else {
                logger.log(source: "system", message: "[error] No primary display found")
                return
            }

            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1fps
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.capturesShadowsOnly = false

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            logger.log(source: "system", message: "[error] Screen recording permission denied — screen capture disabled")
        }
    }

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeSubtract(presentationTime, lastFrameTime).seconds >= 1.0 else { return }
        lastFrameTime = presentationTime

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard deduplicator.isNew(pixelBuffer: pixelBuffer, source: "screen") else { return }

        // Encode to JPEG synchronously before buffer is released
        guard let jpegData = jpegData(from: pixelBuffer) else { return }
        vision.analyze(jpegData: jpegData, source: "screen")
    }

    private func primaryDisplay(from content: SCShareableContent) -> SCDisplay? {
        guard let mainScreen = NSScreen.main else { return content.displays.first }
        let mainID = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first
    }

    private func jpegData(from buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        return context.jpegRepresentation(of: ciImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/banti/ScreenCapture.swift
git commit -m "feat: add ScreenCapture with SCStream, 1fps throttle, primary display selection"
```

---

## Task 8: Wire Everything in main.swift

**Files:**
- Modify: `Sources/banti/main.swift`

- [ ] **Step 1: Implement main.swift**

```swift
// Sources/banti/main.swift
import Foundation
import AppKit

// Shared components
let logger = Logger()
let deduplicator = Deduplicator()
let vision = LocalVision(logger: logger)

logger.log(source: "system", message: "banti starting...")

// Check Ollama availability, then start recheck timer
vision.checkAvailability()
vision.startRecheckTimer()

// Start AX reader
let axReader = AXReader(logger: logger)
axReader.start()

// Start camera capture
let cameraCapture = CameraCapture(logger: logger, deduplicator: deduplicator, vision: vision)
cameraCapture.start()

// Start screen capture (async)
let screenCapture = ScreenCapture(logger: logger, deduplicator: deduplicator, vision: vision)
Task {
    await screenCapture.start()
}

logger.log(source: "system", message: "banti running. Press Ctrl+C to stop.")
RunLoop.main.run()
```

- [ ] **Step 2: Build the app bundle**

```bash
make build
```

Expected: `.build/debug/banti` binary built, `Banti.app` assembled.

- [ ] **Step 3: Run all tests**

```bash
swift test
```

Expected: all tests pass (Logger ×3, Deduplicator ×6, LocalVision ×4).

- [ ] **Step 4: Run banti and verify output**

Ensure Ollama is running with moondream pulled:
```bash
ollama serve &
ollama pull moondream
```

Run banti:
```bash
make run
```

Expected (on first run): macOS will prompt for Screen Recording and Camera permissions. Grant both. Then check stdout for lines like:
```
[2026-03-18T14:23:01.123Z] [source: system] banti starting...
[2026-03-18T14:23:01.125Z] [source: system] banti running. Press Ctrl+C to stop.
[2026-03-18T14:23:01.130Z] [source: ax] app: Xcode, window: main.swift, elements: ...
[2026-03-18T14:23:04.200Z] [source: screen] The user is editing Swift code in Xcode.
[2026-03-18T14:23:04.800Z] [source: camera] A person is sitting at a desk looking at a screen.
```

Verify:
- [ ] Screen and camera log entries appear within ~5 seconds
- [ ] When screen is static for 10+ seconds, log frequency drops (deduplication working)
- [ ] Switch to a different app — AX log entry fires immediately
- [ ] Run for 10 minutes — no crash, no unbounded memory growth in Activity Monitor

- [ ] **Step 5: Commit**

```bash
git add Sources/banti/main.swift
git commit -m "feat: wire all components in main.swift, banti vision MVP complete"
```

---

## Verification Checklist

After Task 8, verify all spec success criteria:

| Criterion | How to verify |
|---|---|
| Screen + camera at ~1fps | Count log lines per 10 seconds — expect ~10 screen + ~10 camera |
| Deduplication working | Leave screen static — log frequency drops to near zero |
| Moondream response within ~3s | Note timestamp of screen change vs. next screen log line |
| AX fires on app switch | Cmd+Tab between apps — AX entry appears immediately |
| 10 min stable run | Leave running, watch Activity Monitor (Memory column) |
| Graceful degradation | Kill Ollama mid-run — `[error]` log appears, capture continues |
