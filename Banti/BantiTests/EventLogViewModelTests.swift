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
                                     responseTime: now,
                                     changeDistance: 0.0)
    }

    func makeModuleStatus() -> ModuleStatusEvent {
        ModuleStatusEvent(moduleID: ModuleID("mic"), oldStatus: "starting", newStatus: "running")
    }

    /// Waits until the VM's entries reach the expected count, or a deadline passes.
    /// Needed because the AsyncStream → subscription task → MainActor hop takes multiple
    /// cooperative scheduler cycles — a single Task.yield() is not sufficient.
    func waitForEntries(_ vm: EventLogViewModel, count: Int) async {
        let deadline = Date().addingTimeInterval(2)
        while vm.entries.count < count, Date() < deadline {
            await Task.yield()
        }
    }

    func waitForLastEntry(_ vm: EventLogViewModel, containing text: String) async {
        let deadline = Date().addingTimeInterval(2)
        while vm.entries.last?.text.contains(text) != true, Date() < deadline {
            await Task.yield()
        }
    }

    // MARK: - Entry appended per event type

    func testAudioFrameCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeAudioFrame(seq: 1))
        await waitForEntries(vm, count: 1)

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[AUDIO]")
    }

    func testSceneChangeCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(SceneChangeEvent(jpeg: Data("fake".utf8), changeDistance: 0.25, sequenceNumber: 1, captureTime: Date()))
        await waitForEntries(vm, count: 1)

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[CHANGE]")
    }

    func testRawTranscriptCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeRawTranscript())
        await waitForEntries(vm, count: 1)

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[RAW]")
    }

    func testTranscriptSegmentCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeSegment())
        await waitForEntries(vm, count: 1)

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[SEGMENT]")
    }

    func testSceneDescriptionCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeScene())
        await waitForEntries(vm, count: 1)

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[SCENE]")
    }

    func testModuleStatusCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeModuleStatus())
        await waitForEntries(vm, count: 1)

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
        await waitForEntries(vm, count: 3)

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
        await waitForEntries(vm, count: 1)
        XCTAssertEqual(vm.entries.count, 1)

        await vm.stopListening()
        await vm.startListening()
        await hub.publish(makeAudioFrame(seq: 51))
        await waitForEntries(vm, count: 2)

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
        await waitForEntries(vm, count: 1)
        let countAfterFirstSession = vm.entries.count

        await vm.startListening()
        await hub.publish(makeAudioFrame(seq: 99))
        await waitForEntries(vm, count: countAfterFirstSession + 1)

        XCTAssertGreaterThan(vm.entries.count, countAfterFirstSession)
    }

    // MARK: - Truncation

    func testTextTruncatedAt120Chars() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        let longText = String(repeating: "a", count: 120)
        await hub.publish(makeSegment(text: longText))
        await waitForEntries(vm, count: 1)

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
        await waitForEntries(vm, count: 1)

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
        await waitForEntries(vm, count: 500)
        XCTAssertEqual(vm.entries.count, 500)

        let secondEntryText = vm.entries[1].text

        await hub.publish(makeScene(text: "scene 500"))
        await waitForLastEntry(vm, containing: "scene 500")

        XCTAssertEqual(vm.entries.count, 500)
        XCTAssertTrue(vm.entries[0].text.contains(secondEntryText.prefix(20)),
                      "Expected buffer to drop oldest entry")
        XCTAssertTrue(vm.entries.last?.text.contains("scene 500") == true)
    }

    // MARK: - AgentResponseEvent

    func makeAgentResponse(userText: String = "what is this?",
                           responseText: String = "That is Figma.") -> AgentResponseEvent {
        AgentResponseEvent(userText: userText, responseText: responseText)
    }

    func testAgentResponseCreatesEntry() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeAgentResponse())
        await waitForEntries(vm, count: 1)

        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].tag, "[AGENT]")
    }

    func testAgentResponseEntryContainsResponseText() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeAgentResponse(responseText: "use a computed property"))
        await waitForEntries(vm, count: 1)

        XCTAssertTrue(vm.entries[0].text.contains("use a computed property"),
                      "Entry text should contain response text")
    }

    func testAgentResponseEntryContainsUserText() async {
        let hub = EventHubActor()
        let vm = EventLogViewModel(eventHub: hub)
        await vm.startListening()

        await hub.publish(makeAgentResponse(userText: "explain closures"))
        await waitForEntries(vm, count: 1)

        XCTAssertTrue(vm.entries[0].text.contains("explain closures"),
                      "Entry text should contain user text")
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
