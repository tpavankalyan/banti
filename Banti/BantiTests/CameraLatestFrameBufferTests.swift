import XCTest
@testable import Banti

final class CameraLatestFrameBufferTests: XCTestCase {
    func testTakeReturnsNilWhenEmpty() {
        let buffer = CameraLatestFrameBuffer()
        XCTAssertNil(buffer.take())
    }

    func testStoreAndTake() {
        let buffer = CameraLatestFrameBuffer()
        let data = Data("frame".utf8)
        buffer.store(data)
        XCTAssertEqual(buffer.take(), data)
    }

    func testTakeClearsBuffer() {
        let buffer = CameraLatestFrameBuffer()
        buffer.store(Data("frame".utf8))
        _ = buffer.take()
        XCTAssertNil(buffer.take())
    }

    func testStoreOverwritesPreviousFrame() {
        let buffer = CameraLatestFrameBuffer()
        buffer.store(Data("frame1".utf8))
        buffer.store(Data("frame2".utf8))
        XCTAssertEqual(buffer.take(), Data("frame2".utf8))
    }
}
