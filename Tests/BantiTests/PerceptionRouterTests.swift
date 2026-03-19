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

    func testSetFaceIdentifierIsStoredOnRouter() async {
        let router = PerceptionRouter(context: PerceptionContext(), logger: Logger())
        let sidecar = MemorySidecar(logger: Logger())
        let identifier = FaceIdentifier(
            context: PerceptionContext(),
            sidecar: sidecar,
            logger: Logger(),
            sessionID: "test"
        )
        await router.setFaceIdentifier(identifier)
        let has = await router.hasFaceIdentifier
        XCTAssertTrue(has)
    }
}
