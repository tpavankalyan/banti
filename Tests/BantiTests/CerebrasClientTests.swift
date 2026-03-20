import XCTest
import Foundation
@testable import BantiCore

final class CerebrasClientTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubCerebrasURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubCerebrasURLProtocol.self)
        super.tearDown()
    }

    func testNon2xxErrorIncludesStatusAndBody() async {
        StubCerebrasURLProtocol.handler = { request in
            let body = #"{"message":"Model llama-3.3-70b does not exist or you do not have access to it.","code":"model_not_found"}"#
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }

        let completion = makeLiveCerebrasCompletion(
            apiKey: "test-key",
            sessionFactory: {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [StubCerebrasURLProtocol.self]
                return URLSession(configuration: config)
            }
        )

        do {
            _ = try await completion("llama-3.3-70b", "system", "user", 10)
            XCTFail("expected the completion to throw")
        } catch {
            let rendered = String(describing: error)
            XCTAssertTrue(rendered.contains("404"), "expected error to include HTTP status, got: \(rendered)")
            XCTAssertTrue(rendered.contains("model_not_found"), "expected error to include response body, got: \(rendered)")
        }
    }
}

private final class StubCerebrasURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.cerebras.ai"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
