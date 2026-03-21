import Foundation
import os

actor TranscriptProjectionActor: BantiModule {
    nonisolated let id = ModuleID("transcript-projection")
    nonisolated let capabilities: Set<Capability> = [.projection]

    private let logger = Logger(subsystem: "com.banti.transcript-projection", category: "Projection")
    private let eventHub: EventHubActor
    private var transcriptSubscriptionID: SubscriptionID?
    private var _health: ModuleHealth = .healthy

    private var speakerMap: [Int: String] = [:]
    private var nextSpeakerNumber = 1
    private var finalizedEndTime: TimeInterval = 0
    private var emittedSegmentCount = 0

    init(eventHub: EventHubActor) {
        self.eventHub = eventHub
    }

    func start() async throws {
        transcriptSubscriptionID = await eventHub.subscribe(RawTranscriptEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleRawTranscript(event)
        }
        _health = .healthy
    }

    func stop() async {
        if let subID = transcriptSubscriptionID {
            await eventHub.unsubscribe(subID)
            transcriptSubscriptionID = nil
        }
    }

    func health() -> ModuleHealth { _health }

    private func handleRawTranscript(_ event: RawTranscriptEvent) async {
        guard !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if event.isFinal {
            if event.audioEndTime <= finalizedEndTime { return }

            let label = speakerLabel(for: event.speakerIndex)
            let segment = TranscriptSegmentEvent(
                speakerLabel: label,
                text: event.text,
                startTime: event.audioStartTime,
                endTime: event.audioEndTime,
                isFinal: true
            )
            finalizedEndTime = max(finalizedEndTime, event.audioEndTime)
            await eventHub.publish(segment)
            emittedSegmentCount += 1
            if emittedSegmentCount == 1 || emittedSegmentCount.isMultiple(of: 10) {
                logger.notice("Published finalized transcript segments count=\(self.emittedSegmentCount)")
            }
        } else {
            let label = speakerLabel(for: event.speakerIndex)
            let segment = TranscriptSegmentEvent(
                speakerLabel: label,
                text: event.text,
                startTime: event.audioStartTime,
                endTime: event.audioEndTime,
                isFinal: false
            )
            await eventHub.publish(segment)
            logger.notice("Published interim transcript for \(label)")
        }
    }

    private func speakerLabel(for index: Int?) -> String {
        guard let index else { return "Speaker ?" }
        if let existing = speakerMap[index] { return existing }
        let label = "Speaker \(nextSpeakerNumber)"
        nextSpeakerNumber += 1
        speakerMap[index] = label
        return label
    }
}
