// Banti/BantiTests/EventLogViewModelTests.swift
import XCTest
@testable import Banti

@MainActor
final class EventLogViewModelTests: XCTestCase {

    // MARK: - Helpers

    func makeAudioFrame(seq: UInt64 = 1) -> AudioFrameEvent {
        AudioFrameEvent(audioData: Data(repeating: 0, count: 64), sequenceNumber: seq)
    }

    func makeCameraFrame(seq: UInt64 = 1) -> CameraFrameEvent {
        CameraFrameEvent(jpeg: Data(repeating: 0, count: 100), sequenceNumber: seq,
                         frameWidth: 640, frameHeight: 480)
    }

    func makeRawTranscript(speaker: Int? = 0, text: String = "hello") -> RawTranscriptEvent {
        RawTranscriptEvent(text: text, speakerIndex: speaker, confidence: 0.91,
                           isFinal: true, audioStartTime: 0, audioEndTime: 1)
    }

    func makeSegment(speaker: String = "Speaker 1", text: String = "hello",
                     isFinal: Bool = true) -> TranscriptSegmentEvent {
        TranscriptSegmentEvent(speakerLabel: speaker, text: text,
                               startTime: 0, endTime: 1, isFinal: isFinal)
    }

    func makeScene(text: String = "A desk") -> SceneDescriptionEvent {
        let now = Date()
        return SceneDescriptionEvent(text: text,
                                     captureTime: now.addingTimeInterval(-1),
                                     responseTime: now)
    }

    func makeModuleStatus() -> ModuleStatusEvent {
        ModuleStatusEvent(moduleID: ModuleID("mic"), oldStatus: "starting", newStatus: "running")
    }

    // MARK: - Entry appended per event type

    func testAudioFrameCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeAudioFrame(seq: 1))
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[AUDIO]")
    }

    func testCameraFrameCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeCameraFrame())
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[CAMERA]")
    }

    func testRawTranscriptCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeRawTranscript())
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[RAW]")
    }

    func testTranscriptSegmentCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeSegment())
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[SEGMENT]")
    }

    func testSceneDescriptionCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeScene())
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[SCENE]")
    }

    func testModuleStatusCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeModuleStatus())
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[MODULE]")
    }

    // MARK: - Audio throttling

    func testAudioOnlyLogsFrame1AndMultiplesOf100() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        for seq in UInt64(1)...200 {
            await hub.publish(makeAudioFrame(seq: seq))
        }
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 3)
        XCTAssertTrue(vm.entries.allSatisfy { $0.tag == "[AUDIO]" })
    }

    func testAudioCounterResetsOnStop() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        for seq in UInt64(1)...50 {
            await hub.publish(makeAudioFrame(seq: seq))
        }
        await Task.yield()
        XCTAssertEqual(vm.entries.count, 1)

        await vm.stopListening()
        await vm.startListening()
        await hub.publish(makeAudioFrame(seq: 51))
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 2)
        XCTAssertEqual(vm.entries[1].tag, "[AUDIO]")
    }

    func testAudioCounterResetsDefensivelyOnStart() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)

        await vm.startListening()
        for seq in UInt64(1)...50 {
            await hub.publish(makeAudioFrame(seq: seq))
        }
        await Task.yield()
        let countAfterFirstSession = vm.entries.count

        await vm.startListening()
        await hub.publish(makeAudioFrame(seq: 99))
        await Task.yield()

        XCTAssertGreaterThan(vm.entries.count, countAfterFirstSession)
    }

    // MARK: - Truncation

    func testTextTruncatedAt120Chars() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        let longText = String(repeating: "a", count: 120)
        await hub.publish(makeSegment(text: longText))
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 1)
        let text = vm.entries[0].text
        XCTAssertTrue(text.hasSuffix("…"), "Expected truncation ellipsis, got: \(text)")
        XCTAssertLessThanOrEqual(text.count, 121)
    }

    func testShortTextIsNotTruncated() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeSegment(text: "short"))
        await Task.yield()

        XCTAssertFalse(vm.entries[0].text.hasSuffix("…"))
    }

    // MARK: - Rolling buffer

    func testRollingBufferCappedAt500() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        for i in 0..<500 {
            await hub.publish(makeScene(text: "scene \(i)"))
        }
        await Task.yield()
        XCTAssertEqual(vm.entries.count, 500)

        let secondEntryText = vm.entries[1].text

        await hub.publish(makeScene(text: "scene 500"))
        await Task.yield()

        XCTAssertEqual(vm.entries.count, 500)
        XCTAssertTrue(vm.entries[0].text.contains(secondEntryText.prefix(20)),
                      "Expected buffer to drop oldest entry")
        XCTAssertTrue(vm.entries.last?.text.contains("scene 500") == true)
    }

    // MARK: - isListening state

    func testIsListeningInitiallyFalse() {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        XCTAssertFalse(vm.isListening)
    }

    func testIsListeningSetOnStartAndStop() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        XCTAssertFalse(vm.isListening)

        await vm.startListening()
        XCTAssertTrue(vm.isListening)

        await vm.stopListening()
        XCTAssertFalse(vm.isListening)
    }
}
