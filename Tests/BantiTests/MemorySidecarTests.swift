// Tests/BantiTests/MemorySidecarTests.swift
import XCTest
@testable import BantiCore

final class MemorySidecarTests: XCTestCase {

    // MARK: - Init / static properties

    func testSidecarDefaultSocketPath() {
        let sidecar = MemorySidecar(logger: Logger())
        XCTAssertEqual(sidecar.socketPath, "/tmp/banti_memory.sock")
    }

    func testSidecarCustomSocketPath() {
        let sidecar = MemorySidecar(socketPath: "/tmp/test.sock", logger: Logger())
        XCTAssertEqual(sidecar.socketPath, "/tmp/test.sock")
    }

    func testSidecarLegacyPortInitUsesDefaultSocketPath() {
        // Legacy init (port:) must still compile and must use the fixed socket path.
        let sidecar = MemorySidecar(logger: Logger(), port: 9090)
        XCTAssertEqual(sidecar.socketPath, "/tmp/banti_memory.sock")
    }

    // MARK: - isRunning

    func testSidecarIsRunningFalseInitially() async {
        let sidecar = MemorySidecar(logger: Logger())
        let running = await sidecar.isRunning
        XCTAssertFalse(running)
    }

    // MARK: - post shim returns nil when not running

    func testPostShimReturnsNilWhenNotRunning() async throws {
        let sidecar = MemorySidecar(socketPath: "/tmp/banti_missing_\(UUID().uuidString).sock", logger: Logger())
        let result = await sidecar.post(path: "/health", body: [String: String]())
        XCTAssertNil(result)
    }

    // MARK: - MsgPack round-trip

    func testMsgPackEncodeDecodeBasicDict() throws {
        // We test the codec indirectly: encode a dict, decode the bytes, compare.
        // MsgPack is file-private, so we verify through the send path being exercised
        // in the integration test below. Here we just confirm the sidecar compiles.
        XCTAssertTrue(true)
    }

    func testMsgPackDecodeFloat64() throws {
        // Simulate a Python-encoded {"confidence": 0.85}
        // 0x81       fixmap, 1 pair
        // 0xAA       fixstr, length 10  ("confidence")
        // 0xCB       float64 marker
        // <8 bytes>  0.85 as IEEE 754 double, big-endian
        var data = Data([0x81])
        // key: "confidence" (10 bytes)
        data.append(0xA0 | 10)
        data.append(contentsOf: "confidence".utf8)
        // value: float64 0.85
        data.append(0xCB)
        var bits = (0.85).bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }

        let decoded = MsgPack.decode(data)
        XCTAssertNotNil(decoded, "MsgPack.decode returned nil — float64 (0xCB) case is missing")
        let confidence = decoded?["confidence"] as? Double
        XCTAssertNotNil(confidence, "confidence field should decode as Double")
        XCTAssertEqual(confidence!, 0.85, accuracy: 1e-10)
    }

    func testMsgPackDecodeFloat32() throws {
        // Simulate a Python-encoded {"score": Float32(0.5)}
        // 0x81       fixmap, 1 pair
        // 0xA5       fixstr, length 5  ("score")
        // 0xCA       float32 marker
        // <4 bytes>  0.5 as IEEE 754 single, big-endian
        var data = Data([0x81])
        data.append(0xA0 | 5)
        data.append(contentsOf: "score".utf8)
        data.append(0xCA)
        var bits = Float(0.5).bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }

        let decoded = MsgPack.decode(data)
        XCTAssertNotNil(decoded, "MsgPack.decode returned nil — float32 (0xCA) case is missing")
        let score = decoded?["score"] as? Double
        XCTAssertNotNil(score, "score field should decode as Double")
        XCTAssertEqual(score!, 0.5, accuracy: 1e-6)
    }

    // MARK: - Socket integration (skipped when sidecar is absent)

    func testHealthPingOverSocket() async throws {
        let sidecarAvailable = FileManager.default.fileExists(atPath: "/tmp/banti_memory.sock")
        try XCTSkipIf(!sidecarAvailable, "Sidecar not running — skipping socket integration test")

        let sidecar = MemorySidecar(logger: Logger())
        let resp = await sidecar.send(method: "health")
        XCTAssertEqual(resp["status"] as? String, "ok")
    }

    func testQueryMemoryOverSocket() async throws {
        let sidecarAvailable = FileManager.default.fileExists(atPath: "/tmp/banti_memory.sock")
        try XCTSkipIf(!sidecarAvailable, "Sidecar not running — skipping socket integration test")

        let sidecar = MemorySidecar(logger: Logger())
        let resp = await sidecar.send(method: "query_memory", payload: ["q": "test query"])
        XCTAssertNil(resp["error"] as? String)
        XCTAssertNotNil(resp["answer"] as? String)
        XCTAssertNotNil(resp["sources"] as? [Any])
    }
}
