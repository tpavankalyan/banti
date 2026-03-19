// Tests/BantiTests/HumeEmotionAnalyzerTests.swift
import XCTest
import CoreGraphics
@testable import BantiCore

final class HumeEmotionAnalyzerTests: XCTestCase {

    func testYFlipConvertsVisionToImageCoordinates() {
        // Vision bounding box: bottom-left origin, normalized
        // Example: bottom 30% of image, left 20%, width 60%, height 40%
        let visionBox = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        let flipped = HumeEmotionAnalyzer.flipBoundingBox(visionBox)

        // Flipped Y = 1 - origin.y - height = 1 - 0.3 - 0.4 = 0.3
        XCTAssertEqual(flipped.origin.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(flipped.origin.y, 0.3, accuracy: 0.001)
        XCTAssertEqual(flipped.width,    0.6, accuracy: 0.001)
        XCTAssertEqual(flipped.height,   0.4, accuracy: 0.001)
    }

    func testYFlipTopFace() {
        // Face at top of image in Vision coords: y=0.7 (high y = near top in bottom-left origin)
        let visionBox = CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.25)
        let flipped = HumeEmotionAnalyzer.flipBoundingBox(visionBox)
        // flipped.y = 1 - 0.7 - 0.25 = 0.05 (near top in image/top-left coords)
        XCTAssertEqual(flipped.origin.y, 0.05, accuracy: 0.001)
    }

    func testAnalyzeReturnsNilWhenJpegDataIsNil() async {
        let logger = Logger()
        let analyzer = HumeEmotionAnalyzer(apiKey: "test", logger: logger)
        let result = await analyzer.analyze(jpegData: nil, events: [])
        XCTAssertNil(result)
    }
}
