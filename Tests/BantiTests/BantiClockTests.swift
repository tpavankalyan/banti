// Tests/BantiTests/BantiClockTests.swift
import XCTest
@testable import BantiCore

final class BantiClockTests: XCTestCase {
    func testNowNsIsMonotonic() {
        let a = BantiClock.nowNs()
        let b = BantiClock.nowNs()
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func testNowNsIsPlausiblyInNanoseconds() {
        // Just verify it's not returning zero
        let ns = BantiClock.nowNs()
        XCTAssertGreaterThan(ns, 0)
    }

    func testNowNsAdvancesByAtLeastOneMicrosecond() throws {
        let a = BantiClock.nowNs()
        Thread.sleep(forTimeInterval: 0.001) // 1ms
        let b = BantiClock.nowNs()
        XCTAssertGreaterThan(b - a, 500_000) // at least 500µs elapsed
    }
}
