// Tests/BantiTests/MemorySidecarTests.swift
import XCTest
@testable import BantiCore

final class MemorySidecarTests: XCTestCase {

    func testSidecarDefaultPortIs7700() {
        XCTAssertEqual(MemorySidecar.defaultPort, 7700)
    }

    func testSidecarBaseURLIncludesPort() {
        let sidecar = MemorySidecar(logger: Logger(), port: 7700)
        XCTAssertEqual(sidecar.baseURL.absoluteString, "http://127.0.0.1:7700")
    }

    func testSidecarBaseURLRespectsCustomPort() {
        let sidecar = MemorySidecar(logger: Logger(), port: 9090)
        XCTAssertEqual(sidecar.baseURL.absoluteString, "http://127.0.0.1:9090")
    }

    func testSidecarIsRunningFalseInitially() async {
        let sidecar = MemorySidecar(logger: Logger())
        let running = await sidecar.isRunning
        XCTAssertFalse(running)
    }

    func testPostJSONReturnsNilWhenNotRunning() async throws {
        let sidecar = MemorySidecar(logger: Logger())
        let result = await sidecar.post(path: "/health", body: [String: String]())
        XCTAssertNil(result)
    }
}
