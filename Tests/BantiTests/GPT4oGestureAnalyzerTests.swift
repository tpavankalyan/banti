// Tests/BantiTests/GPT4oGestureAnalyzerTests.swift
import XCTest
@testable import BantiCore

final class GPT4oGestureAnalyzerTests: XCTestCase {

    func testAnalyzeReturnsNilWhenJpegDataIsNil() async {
        let logger = Logger()
        let analyzer = GPT4oGestureAnalyzer(apiKey: "test", logger: logger)
        let result = await analyzer.analyze(jpegData: nil, events: [])
        XCTAssertNil(result)
    }

    func testKeypointJSONFromEmptyEventsIsEmptyObject() {
        let json = GPT4oGestureAnalyzer.keypointJSON(from: [])
        XCTAssertEqual(json, "{}")
    }
}
