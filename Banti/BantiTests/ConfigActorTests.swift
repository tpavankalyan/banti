import XCTest
@testable import Banti

final class ConfigActorTests: XCTestCase {
    func testParsesExportSyntax() async {
        let content = "export DEEPGRAM_API_KEY=abc123\nexport OTHER_KEY=def456"
        let config = ConfigActor(content: content)
        let val = await config.value(for: "DEEPGRAM_API_KEY")
        XCTAssertEqual(val, "abc123")
    }

    func testParsesPlainSyntax() async {
        let config = ConfigActor(content: "MY_KEY=value")
        let val = await config.value(for: "MY_KEY")
        XCTAssertEqual(val, "value")
    }

    func testIgnoresCommentsAndBlanks() async {
        let content = "# comment\n\nexport KEY=val"
        let config = ConfigActor(content: content)
        let val = await config.value(for: "KEY")
        XCTAssertEqual(val, "val")
        let missing = await config.value(for: "# comment")
        XCTAssertNil(missing)
    }

    func testRequireThrowsOnMissing() async {
        let config = ConfigActor(content: "A=1")
        do {
            _ = try await config.require("MISSING")
            XCTFail("Should throw")
        } catch {}
    }

    func testValueContainingEquals() async {
        let config = ConfigActor(content: "KEY=a=b=c")
        let val = await config.value(for: "KEY")
        XCTAssertEqual(val, "a=b=c")
    }
}
