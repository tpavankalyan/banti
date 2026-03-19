// Tests/BantiTests/LocalVisionTests.swift
import XCTest
@testable import BantiCore

// URLProtocol stub to intercept Ollama HTTP calls without a real server
final class MockOllamaProtocol: URLProtocol {
    static var responseData: Data = Data()
    static var responseStatusCode: Int = 200
    static var requestsReceived: [[String: Any]] = []
    static var shouldFail = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if MockOllamaProtocol.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        // Capture request body for assertions (URLSession converts httpBody to httpBodyStream)
        var bodyData: Data? = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            var data = Data()
            stream.open()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n > 0 { data.append(buf, count: n) }
            }
            stream.close()
            bodyData = data
        }
        if let body = bodyData,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            MockOllamaProtocol.requestsReceived.append(json)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: MockOllamaProtocol.responseStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: MockOllamaProtocol.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LocalVisionTests: XCTestCase {
    var session: URLSession!
    var logger: Logger!
    var logs: [String]!

    override func setUp() {
        super.setUp()
        MockOllamaProtocol.responseData = Data()
        MockOllamaProtocol.responseStatusCode = 200
        MockOllamaProtocol.requestsReceived = []
        MockOllamaProtocol.shouldFail = false

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockOllamaProtocol.self]
        session = URLSession(configuration: config)

        logs = []
        logger = Logger { [weak self] line in self?.logs.append(line) }
    }

    func testAvailabilityCheckSuccess() {
        MockOllamaProtocol.responseData = #"{"models":[]}"#.data(using: .utf8)!
        let vision = LocalVision(session: session, logger: logger)

        let expectation = XCTestExpectation(description: "check completes")
        vision.checkAvailability {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertTrue(vision.isAvailable)
    }

    func testAvailabilityCheckFailure() {
        MockOllamaProtocol.shouldFail = true
        let vision = LocalVision(session: session, logger: logger)

        let expectation = XCTestExpectation(description: "check completes")
        vision.checkAvailability {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertFalse(vision.isAvailable)

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(logs.contains(where: { $0.contains("Ollama not running") }))
    }

    func testAnalyzeIncludesModelAndPrompt() {
        let responseJSON = #"{"response":"a person typing on a keyboard"}"#
        MockOllamaProtocol.responseData = responseJSON.data(using: .utf8)!
        let vision = LocalVision(session: session, logger: logger)
        vision.isAvailable = true
        vision.isFirstRequest = false

        let jpegData = Data([0xFF, 0xD8, 0xFF])  // minimal JPEG header stub
        let expectation = XCTestExpectation(description: "analyze completes")
        vision.analyze(jpegData: jpegData, source: "screen") {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(MockOllamaProtocol.requestsReceived.count, 1)
        let body = MockOllamaProtocol.requestsReceived[0]
        XCTAssertEqual(body["model"] as? String, "moondream")
        XCTAssertNotNil(body["prompt"])

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(logs.contains(where: { $0.contains("[source: screen]") && $0.contains("person typing") }))
    }

    func testAnalyzeSkipsWhenUnavailable() {
        let vision = LocalVision(session: session, logger: logger)
        vision.isAvailable = false

        let jpegData = Data([0xFF, 0xD8, 0xFF])
        let expectation = XCTestExpectation(description: "analyze skips quickly")
        vision.analyze(jpegData: jpegData, source: "screen") {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(MockOllamaProtocol.requestsReceived.count, 0)
    }
}
