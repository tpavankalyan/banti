// Tests/BantiTests/AudioRouterPCMTests.swift
import XCTest
@testable import BantiCore

final class AudioRouterPCMTests: XCTestCase {

    func testPCMRingBufferMaxBytesIs160000() {
        XCTAssertEqual(AudioRouter.pcmRingBufferMaxBytes, 160_000)
    }

    func testRingBufferStartsEmpty() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let data = await router.readPCMRingBuffer()
        XCTAssertTrue(data.isEmpty)
    }

    func testAppendAccumulatesData() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 1, count: 1_000)
        await router.appendToPCMRingBuffer(chunk)
        await router.appendToPCMRingBuffer(chunk)
        let data = await router.readPCMRingBuffer()
        XCTAssertEqual(data.count, 2_000)
    }

    func testBufferTrimsToMaxWhenOverflowed() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 0, count: 170_000)
        await router.appendToPCMRingBuffer(chunk)
        let data = await router.readPCMRingBuffer()
        XCTAssertEqual(data.count, AudioRouter.pcmRingBufferMaxBytes)
    }

    func testReadIsNonDestructive() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 2, count: 5_000)
        await router.appendToPCMRingBuffer(chunk)
        let read1 = await router.readPCMRingBuffer()
        let read2 = await router.readPCMRingBuffer()
        XCTAssertEqual(read1, read2)
        XCTAssertEqual(read2.count, 5_000)
    }

    func testDispatchCallsAppendToPCMBuffer() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 0, count: 32_000)
        await router.dispatch(pcmChunk: chunk)
        let data = await router.readPCMRingBuffer()
        XCTAssertEqual(data.count, 32_000)
    }
}
