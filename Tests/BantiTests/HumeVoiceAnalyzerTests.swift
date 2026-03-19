// Tests/BantiTests/HumeVoiceAnalyzerTests.swift
import XCTest
@testable import BantiCore

final class HumeVoiceAnalyzerTests: XCTestCase {

    // MARK: WAV header

    func testWAVHeaderByteLayout() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = HumeVoiceAnalyzer.makeWAV(pcmData: pcm)
        XCTAssertEqual(wav.count, 144)  // 44-byte header + 100 bytes data
        XCTAssertEqual(wav[0..<4], "RIFF".data(using: .utf8)!)
        XCTAssertEqual(wav[4..<8], Data([136, 0, 0, 0]))   // 100+36=136 LE
        XCTAssertEqual(wav[8..<12], "WAVE".data(using: .utf8)!)
        XCTAssertEqual(wav[12..<16], "fmt ".data(using: .utf8)!)
        XCTAssertEqual(wav[16..<20], Data([16, 0, 0, 0]))  // fmt chunk size = 16
        XCTAssertEqual(wav[20..<22], Data([1, 0]))          // PCM format
        XCTAssertEqual(wav[22..<24], Data([1, 0]))          // mono
        XCTAssertEqual(wav[24..<28], Data([0x80, 0x3E, 0x00, 0x00]))  // 16000 LE
        XCTAssertEqual(wav[28..<32], Data([0x00, 0x7D, 0x00, 0x00]))  // 32000 LE
        XCTAssertEqual(wav[32..<34], Data([2, 0]))          // block align
        XCTAssertEqual(wav[34..<36], Data([16, 0]))         // bits per sample
        XCTAssertEqual(wav[36..<40], "data".data(using: .utf8)!)
        XCTAssertEqual(wav[40..<44], Data([100, 0, 0, 0])) // data size LE
    }

    func testWAVPayloadIsAppended() {
        let pcm = Data([0x01, 0x02, 0x03])
        let wav = HumeVoiceAnalyzer.makeWAV(pcmData: pcm)
        XCTAssertEqual(wav.suffix(3), Data([0x01, 0x02, 0x03]))
    }

    // MARK: Response parsing

    func testParseResponseExtractsProsodyEmotions() {
        let json = """
        {
          "prosody": {
            "predictions": [{
              "emotions": [
                { "name": "Joy", "score": 0.87 },
                { "name": "Calm", "score": 0.45 }
              ]
            }]
          }
        }
        """
        let state = HumeVoiceAnalyzer.parseResponse(json.data(using: .utf8)!)
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.emotions.count, 2)
        XCTAssertEqual(state?.emotions.first?.label, "Joy")
        XCTAssertEqual(state?.emotions.first?.score ?? 0, 0.87, accuracy: 0.001)
    }

    func testParseResponseReturnsNilForMissingProsody() {
        let json = "{ \"face\": {} }"
        XCTAssertNil(HumeVoiceAnalyzer.parseResponse(json.data(using: .utf8)!))
    }

    func testParseResponseReturnsNilForEmptyPredictions() {
        let json = "{ \"prosody\": { \"predictions\": [] } }"
        XCTAssertNil(HumeVoiceAnalyzer.parseResponse(json.data(using: .utf8)!))
    }

    func testAnalyzeReturnsNilForEmptyPCM() async {
        let analyzer = HumeVoiceAnalyzer(apiKey: "test", context: PerceptionContext(), logger: Logger())
        let result = await analyzer.analyze(pcmData: Data())
        XCTAssertNil(result)
    }
}
