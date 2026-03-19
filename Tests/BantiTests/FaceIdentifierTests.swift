// Tests/BantiTests/FaceIdentifierTests.swift
import XCTest
import Vision
@testable import BantiCore

final class FaceIdentifierTests: XCTestCase {

    func testDispatchSkipsWhenSidecarNotRunning() async {
        let context = PerceptionContext()
        let sidecar = MemorySidecar(logger: Logger())
        let identifier = FaceIdentifier(context: context, sidecar: sidecar, logger: Logger(), sessionID: "test-session")
        let fakeJpeg = Data(repeating: 0, count: 100)
        let obs = VNFaceObservation(boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5))
        await identifier.dispatch(jpegData: fakeJpeg, faceObservation: obs)
        let person = await context.person
        XCTAssertNil(person)
    }

    func testSessionIDIsStored() {
        let identifier = FaceIdentifier(
            context: PerceptionContext(),
            sidecar: MemorySidecar(logger: Logger()),
            logger: Logger(),
            sessionID: "abc-123"
        )
        XCTAssertEqual(identifier.sessionID, "abc-123")
    }
}
