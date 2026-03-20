import XCTest
@testable import BantiCore

final class NodeConfigTests: XCTestCase {
    func testParsesNodeEntries() throws {
        let yaml = """
        nodes:
          brainstem:
            model: llama3.1-8b
            subscribes: [brain.route]
            publishes: [brain.brainstem.response]
            prompt_file: prompts/brainstem.md
            timeout_s: 3
        """
        let config = try NodeConfig.parse(yaml: yaml)
        let brainstem = try XCTUnwrap(config.nodes["brainstem"])
        XCTAssertEqual(brainstem.model, "llama3.1-8b")
        XCTAssertEqual(brainstem.subscribes, ["brain.route"])
        XCTAssertEqual(brainstem.timeoutS, 3)
    }

    func testHandlesMissingOptionalFields() throws {
        let yaml = """
        nodes:
          minimal:
            model: llama3.1-8b
        """
        let config = try NodeConfig.parse(yaml: yaml)
        let minimal = try XCTUnwrap(config.nodes["minimal"])
        XCTAssertEqual(minimal.model, "llama3.1-8b")
        XCTAssertNil(minimal.timeoutS)
        XCTAssertNil(minimal.promptFile)
    }
}
