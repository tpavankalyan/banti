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
    private var lastScreenLog: Date = .distantPast

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
        // Clean up any existing subscriptions before re-subscribing (defensive against double-call)
        for id in subscriptionIDs {
            await eventHub.unsubscribe(id)
        }
        subscriptionIDs.removeAll()
        audioFrameCount = 0
        lastScreenLog = .distantPast
        subscriptionIDs.append(await eventHub.subscribe(AudioFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleAudio(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(SceneChangeEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[CHANGE]", text: self.format(event))
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
        subscriptionIDs.append(await eventHub.subscribe(ScreenFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleScreen(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(ScreenDescriptionEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[SCREEN]", text: self.format(event))
        })
        subscriptionIDs.append(await eventHub.subscribe(ActiveAppEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[APP]", text: self.format(event))
        })
        subscriptionIDs.append(await eventHub.subscribe(AXFocusEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[AX]", text: self.format(event))
        })
        subscriptionIDs.append(await eventHub.subscribe(AgentResponseEvent.self) { [weak self] event in
            guard let self else { return }
            await self.append(tag: "[AGENT]", text: self.format(event))
        })
        isListening = true
    }

    func stopListening() async {
        for id in subscriptionIDs {
            await eventHub.unsubscribe(id)
        }
        subscriptionIDs.removeAll()
        audioFrameCount = 0
        lastScreenLog = .distantPast
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

    private func handleScreen(_ event: ScreenFrameEvent) {
        let now = Date()
        guard now.timeIntervalSince(lastScreenLog) >= 60 else { return }
        lastScreenLog = now
        append(tag: "[SCRFRM]", text: format(event))
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

    private func format(_ e: SceneChangeEvent) -> String {
        e.changeDistance == 0
            ? "seq=\(e.sequenceNumber) first-frame"
            : "seq=\(e.sequenceNumber) dist=\(String(format: "%.3f", e.changeDistance))"
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

    private func format(_ e: ScreenFrameEvent) -> String {
        "frame=\(e.sequenceNumber) size=\(e.displayWidth)x\(e.displayHeight)"
    }

    private func format(_ e: ScreenDescriptionEvent) -> String {
        let ms = Int(e.responseTime.timeIntervalSince(e.captureTime) * 1000)
        return "latency=\(ms)ms | \(e.text)"
    }

    private func format(_ e: ActiveAppEvent) -> String {
        let prev = e.previousAppName.map { "\($0) → " } ?? ""
        return "\(prev)\(e.appName) (\(e.bundleIdentifier))"
    }

    private func format(_ e: AgentResponseEvent) -> String {
        "Q: \(e.userText) | A: \(e.responseText)"
    }

    private func format(_ e: AXFocusEvent) -> String {
        var parts = "\(e.changeKind.rawValue) | \(e.appName) | \(e.elementRole)"
        if let title = e.elementTitle { parts += " · \(title)" }
        if let sel = e.selectedText { parts += " | selected: '\(String(sel.prefix(40)))'" }
        return parts
    }
}
