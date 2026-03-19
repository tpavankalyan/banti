// Tests/BantiTests/MemoryIngestorTests.swift
import XCTest
@testable import BantiCore

final class MemoryIngestorTests: XCTestCase {

    func testPollIntervalIs2Seconds() {
        XCTAssertEqual(MemoryIngestor.pollIntervalNanoseconds, 2_000_000_000)
    }

    func testMaxBufferSizeIs100() {
        XCTAssertEqual(MemoryIngestor.maxBufferSize, 100)
    }

    func testDuplicateSnapshotIsFiltered() {
        let snapshot = "{\"speech\":{\"transcript\":\"hello\"}}"
        XCTAssertTrue(MemoryIngestor.isDuplicate(snapshot, previous: snapshot))
    }

    func testDifferentSnapshotIsNotDuplicate() {
        let a = "{\"speech\":{\"transcript\":\"hello\"}}"
        let b = "{\"speech\":{\"transcript\":\"world\"}}"
        XCTAssertFalse(MemoryIngestor.isDuplicate(a, previous: b))
    }

    func testEmptySnapshotIsFiltered() {
        XCTAssertTrue(MemoryIngestor.isEmpty("{}"))
        XCTAssertTrue(MemoryIngestor.isEmpty(""))
        XCTAssertFalse(MemoryIngestor.isEmpty("{\"activity\":{\"description\":\"typing\"}}"))
    }
}
