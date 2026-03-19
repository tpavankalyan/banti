// Tests/BantiTests/SpeakerResolverTests.swift
import XCTest
@testable import BantiCore

final class SpeakerResolverTests: XCTestCase {

    func testMinAccumulationBytesIs96000() {
        XCTAssertEqual(SpeakerResolver.minAccumulationBytes, 96_000)
    }

    func testSessionMapLookupReturnsCachedName() async {
        let resolver = SpeakerResolver(
            context: PerceptionContext(),
            audioRouter: AudioRouter(context: PerceptionContext(), logger: Logger()),
            sidecar: MemorySidecar(logger: Logger()),
            logger: Logger(),
            sessionID: "test"
        )
        await resolver.cacheResolvedName("Alice", forSpeakerID: 2)
        let name = await resolver.resolvedName(forSpeakerID: 2)
        XCTAssertEqual(name, "Alice")
    }

    func testSessionMapReturnsNilForUnknownSpeaker() async {
        let resolver = SpeakerResolver(
            context: PerceptionContext(),
            audioRouter: AudioRouter(context: PerceptionContext(), logger: Logger()),
            sidecar: MemorySidecar(logger: Logger()),
            logger: Logger(),
            sessionID: "test"
        )
        let name = await resolver.resolvedName(forSpeakerID: 99)
        XCTAssertNil(name)
    }

    func testPendingTrackerIsEmpty() async {
        let resolver = SpeakerResolver(
            context: PerceptionContext(),
            audioRouter: AudioRouter(context: PerceptionContext(), logger: Logger()),
            sidecar: MemorySidecar(logger: Logger()),
            logger: Logger(),
            sessionID: "test"
        )
        let pending = await resolver.pendingSpeakerIDs
        XCTAssertTrue(pending.isEmpty)
    }
}
