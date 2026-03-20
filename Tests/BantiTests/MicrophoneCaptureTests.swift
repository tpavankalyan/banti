import XCTest
@testable import BantiCore

final class MicrophoneCaptureTests: XCTestCase {
    func testRelativePeakLevelIsZeroForSilence() {
        let chunk = Data(repeating: 0, count: 64)
        XCTAssertEqual(MicrophoneCapture.relativePeakLevel(for: chunk), 0.0, accuracy: 0.0001)
    }

    func testRelativePeakLevelReflectsNonZeroPCM() {
        let samples: [Int16] = [0, 8192, -16384, 32767]
        let chunk = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let level = MicrophoneCapture.relativePeakLevel(for: chunk)
        XCTAssertGreaterThan(level, 0.9)
        XCTAssertLessThanOrEqual(level, 1.0)
    }
}
