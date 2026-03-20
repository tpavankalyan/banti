import XCTest
@testable import Banti

final class DeepgramParsingTests: XCTestCase {
    func testDecodesFullResponseWithWords() throws {
        let json = """
        {
            "channel": {
                "alternatives": [{
                    "transcript": "hello world",
                    "confidence": 0.95,
                    "words": [
                        {"word": "hello", "start": 0.0, "end": 0.5,
                         "confidence": 0.97, "speaker": 0, "punctuated_word": "Hello"},
                        {"word": "world", "start": 0.5, "end": 1.0,
                         "confidence": 0.93, "speaker": 0, "punctuated_word": "world."}
                    ]
                }]
            },
            "is_final": true,
            "start": 0.0,
            "duration": 1.0
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        XCTAssertTrue(response.isFinal ?? false)
        XCTAssertEqual(response.channel?.alternatives?.first?.words?.count, 2)
        XCTAssertEqual(response.channel?.alternatives?.first?.words?[0].speaker, 0)
        XCTAssertEqual(response.channel?.alternatives?.first?.words?[0].punctuatedWord, "Hello")
    }

    func testDecodesResponseWithoutWords() throws {
        let json = """
        {
            "channel": {
                "alternatives": [{
                    "transcript": "hello",
                    "confidence": 0.9
                }]
            },
            "is_final": false,
            "start": 0.0,
            "duration": 0.5
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        XCTAssertFalse(response.isFinal ?? true)
        XCTAssertNil(response.channel?.alternatives?.first?.words)
        XCTAssertEqual(response.channel?.alternatives?.first?.transcript, "hello")
    }

    func testDecodesMinimalResponse() throws {
        let json = "{}"
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        XCTAssertNil(response.channel)
    }
}
