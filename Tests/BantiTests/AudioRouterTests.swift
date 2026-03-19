// Tests/BantiTests/AudioRouterTests.swift
import XCTest
@testable import BantiCore

final class AudioRouterTests: XCTestCase {

    func testHumeFlushThresholdIs96000Bytes() {
        XCTAssertEqual(AudioRouter.humeFlushThreshold, 96_000)
    }

    func testBufferAccumulatesBeforeThreshold() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 0, count: 1_000)
        for _ in 0..<95 { await router.dispatch(pcmChunk: chunk) }
        let count = await router.humeBufferCount
        XCTAssertEqual(count, 95_000)
    }

    func testBufferResetsAfterThreshold() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 0, count: 1_000)
        for _ in 0..<96 { await router.dispatch(pcmChunk: chunk) }
        let count = await router.humeBufferCount
        XCTAssertEqual(count, 0)
    }

    func testBufferContinuesAccumulatingAfterFlush() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 0, count: 1_000)
        for _ in 0..<101 { await router.dispatch(pcmChunk: chunk) }
        let count = await router.humeBufferCount
        XCTAssertEqual(count, 5_000)
    }

    func testBufferResetsAtThresholdEvenWithoutHumeKey() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 0, count: 1_000)
        for _ in 0..<96 { await router.dispatch(pcmChunk: chunk) }
        let count = await router.humeBufferCount
        XCTAssertEqual(count, 0, "Buffer must reset at threshold even when hume analyzer is nil")
    }

    func testConfigureWithNilKeysDisablesBothAnalyzers() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        await router.configureWith(deepgramKey: nil, humeKey: nil)
        let hasDG = await router.hasDeepgram
        let hasH  = await router.hasHume
        XCTAssertFalse(hasDG)
        XCTAssertFalse(hasH)
    }

    func testConfigureWithDeepgramKeyEnablesDeepgram() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        await router.configureWith(deepgramKey: "dg-test-key", humeKey: nil)
        let hasDG = await router.hasDeepgram
        let hasH  = await router.hasHume
        XCTAssertTrue(hasDG)
        XCTAssertFalse(hasH)
    }

    func testConfigureWithBothKeysEnablesBothAnalyzers() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        await router.configureWith(deepgramKey: "dg-key", humeKey: "hume-key")
        let hasDG = await router.hasDeepgram
        let hasH  = await router.hasHume
        XCTAssertTrue(hasDG)
        XCTAssertTrue(hasH)
    }
}
