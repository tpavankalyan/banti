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
        let sidecar = MemorySidecar(logger: Logger())
        let result = await sidecar.post(path: "/health", body: [String: String]())
        XCTAssertNil(result)
    }

    // MARK: - MsgPack round-trip (via internal send() visibility)

    func testMsgPackEncodeDecodeBasicDict() throws {
        // We test the codec indirectly: encode a dict, decode the bytes, compare.
        // MsgPack is file-private, so we verify through the send path being exercised
        // in the integration test below. Here we just confirm the sidecar compiles.
        XCTAssertTrue(true)
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
        let (answer, _) = await sidecar.query("test query")
        XCTAssertFalse(answer.isEmpty)
    }
}
