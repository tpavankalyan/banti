import Foundation
import os

/// Passive observer that logs every perception event to Console.app.
/// Filter in Console with: category == "EventLog"
actor EventLoggerActor: BantiModule {
    nonisolated let id = ModuleID("event-logger")
    nonisolated let capabilities: Set<Capability> = []

    private let logger = Logger(subsystem: "com.banti.core", category: "EventLog")
    private let eventHub: EventHubActor
    private var subscriptionIDs: [SubscriptionID] = []
    private var audioFrameCount: UInt64 = 0
    private var _health: ModuleHealth = .healthy

    init(eventHub: EventHubActor) {
        self.eventHub = eventHub
    }

    func start() async throws {
        subscriptionIDs.append(await eventHub.subscribe(AudioFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logAudio(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(CameraFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logCamera(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(RawTranscriptEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logRawTranscript(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(TranscriptSegmentEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logTranscriptSegment(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(SceneDescriptionEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logSceneDescription(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(ModuleStatusEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logModuleStatus(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(ScreenFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logScreenFrame(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(ScreenDescriptionEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logScreenDescription(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(ActiveAppEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logActiveApp(event)
        })
        subscriptionIDs.append(await eventHub.subscribe(AXFocusEvent.self) { [weak self] event in
            guard let self else { return }
            await self.logAXFocus(event)
        })
        _health = .healthy
        logger.notice("EventLoggerActor started — subscribed to 10 event types")
    }

    func stop() async {
        for subID in subscriptionIDs {
            await eventHub.unsubscribe(subID)
        }
        subscriptionIDs.removeAll()
        audioFrameCount = 0
    }

    func health() async -> ModuleHealth { _health }

    // MARK: - Per-event log methods

    private func logAudio(_ event: AudioFrameEvent) {
        audioFrameCount += 1
        guard audioFrameCount == 1 || audioFrameCount % 100 == 0 else { return }
        logger.debug("AudioFrame seq=\(event.sequenceNumber) bytes=\(event.audioData.count) sampleRate=\(event.sampleRate)")
    }

    private func logCamera(_ event: CameraFrameEvent) {
        logger.debug("CameraFrame seq=\(event.sequenceNumber) bytes=\(event.jpeg.count) size=\(event.frameWidth)x\(event.frameHeight)")
    }

    private func logRawTranscript(_ event: RawTranscriptEvent) {
        let speaker = event.speakerIndex.map { "Speaker \($0)" } ?? "unknown"
        logger.debug("RawTranscript speaker=\(speaker, privacy: .public) confidence=\(event.confidence, format: .fixed(precision: 2)) final=\(event.isFinal) text=\(String(event.text.prefix(80)), privacy: .public)")
    }

    private func logTranscriptSegment(_ event: TranscriptSegmentEvent) {
        logger.notice("TranscriptSegment speaker=\(event.speakerLabel, privacy: .public) final=\(event.isFinal) text=\(String(event.text.prefix(80)), privacy: .public)")
    }

    private func logSceneDescription(_ event: SceneDescriptionEvent) {
        let latencyMs = Int(event.responseTime.timeIntervalSince(event.captureTime) * 1000)
        logger.notice("SceneDescription latency=\(latencyMs)ms text=\(String(event.text.prefix(60)), privacy: .public)")
    }

    private func logModuleStatus(_ event: ModuleStatusEvent) {
        logger.notice("ModuleStatus module=\(event.moduleID.rawValue, privacy: .public) \(event.oldStatus, privacy: .public) → \(event.newStatus, privacy: .public)")
    }

    private func logScreenFrame(_ event: ScreenFrameEvent) {
        logger.debug("ScreenFrame seq=\(event.sequenceNumber) bytes=\(event.jpeg.count) size=\(event.displayWidth)x\(event.displayHeight)")
    }

    private func logScreenDescription(_ event: ScreenDescriptionEvent) {
        let latencyMs = Int(event.responseTime.timeIntervalSince(event.captureTime) * 1000)
        logger.notice("ScreenDescription latency=\(latencyMs)ms text=\(String(event.text.prefix(60)), privacy: .public)")
    }

    private func logActiveApp(_ event: ActiveAppEvent) {
        let prev = event.previousAppName ?? "none"
        logger.notice("ActiveApp \(prev, privacy: .public) → \(event.appName, privacy: .public) (\(event.bundleIdentifier, privacy: .public))")
    }

    private func logAXFocus(_ event: AXFocusEvent) {
        let selection = event.selectedText.map { " selected='\(String($0.prefix(40)))'" } ?? ""
        logger.notice("AXFocus kind=\(event.changeKind.rawValue, privacy: .public) app=\(event.appName, privacy: .public) role=\(event.elementRole, privacy: .public)\(selection, privacy: .public)")
    }
}
