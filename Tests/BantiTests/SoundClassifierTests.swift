// Tests/BantiTests/SoundClassifierTests.swift
import XCTest
import AVFoundation
@testable import BantiCore

final class SoundClassifierTests: XCTestCase {

    func testFramePositionStartsAtZero() {
        let classifier = SoundClassifier(context: PerceptionContext(), logger: Logger())
        XCTAssertEqual(classifier.currentFramePosition, 0)
    }

    func testFramePositionIncrementsBy1024() {
        let classifier = SoundClassifier(context: PerceptionContext(), logger: Logger())
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 44100, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            XCTFail("Could not create buffer"); return
        }
        buf.frameLength = 1024
        classifier.analyze(buffer: buf)
        XCTAssertEqual(classifier.currentFramePosition, 1024)
    }

    func testFramePositionIncrementsMonotonically() {
        let classifier = SoundClassifier(context: PerceptionContext(), logger: Logger())
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 44100, channels: 1, interleaved: false)!
        for frameLength in [1024, 512, 2048] as [AVAudioFrameCount] {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
                XCTFail("Could not create buffer"); return
            }
            buf.frameLength = frameLength
            classifier.analyze(buffer: buf)
        }
        XCTAssertEqual(classifier.currentFramePosition, 3584)  // 1024+512+2048
    }

    func testFramePositionNeverResets() {
        let classifier = SoundClassifier(context: PerceptionContext(), logger: Logger())
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 44100, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512) else {
            XCTFail("Could not create buffer"); return
        }
        buf.frameLength = 512
        classifier.analyze(buffer: buf)
        classifier.analyze(buffer: buf)
        classifier.analyze(buffer: buf)
        XCTAssertEqual(classifier.currentFramePosition, 1536)
        XCTAssertGreaterThan(classifier.currentFramePosition, 512)
    }
}
