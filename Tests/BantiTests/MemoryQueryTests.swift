// Tests/BantiTests/MemoryQueryTests.swift
import XCTest
@testable import BantiCore

final class MemoryQueryTests: XCTestCase {

    func testQueryReturnsFallbackWhenSidecarNotRunning() async {
        let sidecar = MemorySidecar(logger: Logger())
        let query = MemoryQuery(sidecar: sidecar, logger: Logger())
        let response = await query.query("who is Alice?")
        XCTAssertFalse(response.answer.isEmpty)
        XCTAssertTrue(response.sources.isEmpty)
    }

    func testMemoryResponseDefaultsToEmptySources() {
        let response = MemoryResponse(answer: "test answer")
        XCTAssertEqual(response.sources, [])
        XCTAssertEqual(response.answer, "test answer")
    }
}
