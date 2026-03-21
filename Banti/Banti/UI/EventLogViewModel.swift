// Banti/Banti/UI/EventLogViewModel.swift
import Foundation
import SwiftUI

@MainActor
final class EventLogViewModel: ObservableObject {
    @Published var entries: [EventLogEntry] = []
    @Published var isListening = false
    @Published var errorMessage: String?

    private let eventHub: EventHubActor
    private var subscriptionIDs: [SubscriptionID] = []
    private var audioFrameCount: UInt64 = 0

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    init(eventHub: EventHubActor) {
        self.eventHub = eventHub
    }

    // MARK: - Lifecycle

    func startListening() async {
        audioFrameCount = 0
        subscriptionIDs.append(await eventHub.subscribe(AudioFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleAudio(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(CameraFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[CAMERA]", text: self.format(event))
        })
        subscriptionIDs.append(await eventHub.subscribe(RawTranscriptEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[RAW]", text: self.format(event))
        })
        subscriptionIDs.append(await eventHub.subscribe(TranscriptSegmentEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[SEGMENT]", text: self.format(event))
        })
        subscriptionIDs.append(await eventHub.subscribe(SceneDescriptionEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[SCENE]", text: self.format(event))
        })
        subscriptionIDs.append(await eventHub.subscribe(ModuleStatusEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[MODULE]", text: self.format(event))
        })
        isListening = true
    }

    func stopListening() async {
        for id in subscriptionIDs {
            await eventHub.unsubscribe(id)
        }
        subscriptionIDs.removeAll()
        audioFrameCount = 0
        isListening = false
    }

    func setError(_ message: String) {
        errorMessage = message
    }

    // MARK: - Private

    private func handleAudio(_ event: AudioFrameEvent) {
        audioFrameCount += 1
        guard audioFrameCount == 1 || audioFrameCount % 100 == 0 else { return }
        append(tag: "[AUDIO]", text: format(event))
    }

    private func append(tag: String, text: String) {
        let truncated = text.count > 120 ? String(text.prefix(120)) + "…" : text
        let entry = EventLogEntry(
            id: UUID(),
            tag: tag,
            text: truncated,
            timestampFormatted: Self.timestampFormatter.string(from: Date())
        )
        if entries.count >= 500 { entries.removeFirst() }
        entries.append(entry)
    }

    // MARK: - Formatters

    private func format(_ e: AudioFrameEvent) -> String {
        "frame=\(e.sequenceNumber) bytes=\(e.audioData.count)"
    }

    private func format(_ e: CameraFrameEvent) -> String {
        "frame=\(e.sequenceNumber) bytes=\(e.jpeg.count) size=\(e.frameWidth)x\(e.frameHeight)"
    }

    private func format(_ e: RawTranscriptEvent) -> String {
        let speaker = e.speakerIndex.map { "Speaker \($0)" } ?? "unknown"
        return "\(speaker) | conf=\(String(format: "%.2f", e.confidence)) | \(e.text)"
    }

    private func format(_ e: TranscriptSegmentEvent) -> String {
        "\(e.speakerLabel) | \(e.isFinal ? "final" : "interim") | \(e.text)"
    }

    private func format(_ e: SceneDescriptionEvent) -> String {
        let ms = Int(e.responseTime.timeIntervalSince(e.captureTime) * 1000)
        return "latency=\(ms)ms | \(e.text)"
    }

    private func format(_ e: ModuleStatusEvent) -> String {
        "\(e.moduleID.rawValue): \(e.oldStatus) \u{2192} \(e.newStatus)"
    }
}
