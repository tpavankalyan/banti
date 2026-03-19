// Tests/BantiTests/DeduplicatorTests.swift
import XCTest
@testable import BantiCore

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
