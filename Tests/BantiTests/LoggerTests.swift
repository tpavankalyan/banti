// Tests/BantiTests/LoggerTests.swift
import XCTest
@testable import BantiCore

final class LoggerTests: XCTestCase {

    func testLogFormatsCorrectly() {
        var output: [String] = []
        let logger = Logger { line in output.append(line) }

        logger.log(source: "screen", message: "user is coding")

        // Give the serial queue time to flush
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(output.count, 1)
        let line = output[0]
        XCTAssertTrue(line.contains("[source: screen]"), "Missing source tag: \(line)")
        XCTAssertTrue(line.contains("user is coding"), "Missing message: \(line)")
        // ISO8601 format: starts with year
        XCTAssertTrue(line.hasPrefix("[20"), "Missing ISO8601 timestamp: \(line)")
    }

    func testLogSourceVariants() {
        var output: [String] = []
        let logger = Logger { line in output.append(line) }

        logger.log(source: "camera", message: "face detected")
        logger.log(source: "ax", message: "xcode focused")
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(output.count, 2)
        XCTAssertTrue(output[0].contains("[source: camera]"))
        XCTAssertTrue(output[1].contains("[source: ax]"))
    }

    func testLogIsQueueSafe() {
        var output: [String] = []
        let lock = NSLock()
        let logger = Logger { line in
            lock.lock()
            output.append(line)
            lock.unlock()
        }

        let group = DispatchGroup()
        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                logger.log(source: "screen", message: "msg \(i)")
                group.leave()
            }
        }
        group.wait()
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(output.count, 20)
    }

    func testDeepgramSourceLogsWithoutCrash() {
        var output = ""
        let logger = Logger { output = $0 }
        logger.log(source: "deepgram", message: "transcript received")
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(output.contains("deepgram"))
        XCTAssertTrue(output.contains("transcript received"))
    }

    func testHumeVoiceSourceLogs() {
        var output = ""
        let logger = Logger { output = $0 }
        logger.log(source: "hume-voice", message: "prosody result")
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(output.contains("hume-voice"))
    }
}
