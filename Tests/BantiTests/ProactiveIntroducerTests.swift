// Tests/BantiTests/ProactiveIntroducerTests.swift
import XCTest
@testable import BantiCore

final class ProactiveIntroducerTests: XCTestCase {

    func testFirstPromptThresholdIs30Seconds() {
        XCTAssertEqual(ProactiveIntroducer.firstPromptThreshold, 30.0)
    }

    func testSecondPromptThresholdIs60Seconds() {
        XCTAssertEqual(ProactiveIntroducer.secondPromptThreshold, 60.0)
    }

    func testShouldPromptFirstTimeAfter30Seconds() {
        let firstSeen = Date(timeIntervalSinceNow: -31)
        let result = ProactiveIntroducer.shouldPrompt(
            firstSeen: firstSeen,
            hasPromptedOnce: false,
            hasPromptedTwice: false,
            now: Date()
        )
        XCTAssertTrue(result)
    }

    func testShouldNotPromptBefore30Seconds() {
        let firstSeen = Date(timeIntervalSinceNow: -10)
        let result = ProactiveIntroducer.shouldPrompt(
            firstSeen: firstSeen,
            hasPromptedOnce: false,
            hasPromptedTwice: false,
            now: Date()
        )
        XCTAssertFalse(result)
    }

    func testShouldPromptSecondTimeAfter60Seconds() {
        let firstSeen = Date(timeIntervalSinceNow: -65)
        let result = ProactiveIntroducer.shouldPrompt(
            firstSeen: firstSeen,
            hasPromptedOnce: true,
            hasPromptedTwice: false,
            now: Date()
        )
        XCTAssertTrue(result)
    }

    func testShouldNotPromptAfterTwoPrompts() {
        let firstSeen = Date(timeIntervalSinceNow: -120)
        let result = ProactiveIntroducer.shouldPrompt(
            firstSeen: firstSeen,
            hasPromptedOnce: true,
            hasPromptedTwice: true,
            now: Date()
        )
        XCTAssertFalse(result)
    }

    func testPersonSeenWithNameStopsTracking() async {
        let introducer = ProactiveIntroducer(logger: Logger())
        await introducer.personSeen("p_001", name: nil)
        let isTracked1 = await introducer.isTracking("p_001")
        XCTAssertTrue(isTracked1)
        await introducer.personSeen("p_001", name: "Alice")
        let isTracked2 = await introducer.isTracking("p_001")
        XCTAssertFalse(isTracked2)
    }

    func testPersonSeenUnknownBeginsTracking() async {
        let introducer = ProactiveIntroducer(logger: Logger())
        await introducer.personSeen("p_002", name: nil)
        let isTracked = await introducer.isTracking("p_002")
        XCTAssertTrue(isTracked)
    }
}
