// Banti/Banti/Modules/Perception/Screen/ScreenChangeDetectionActor.swift
import Foundation
import os

actor ScreenChangeDetectionActor: BantiModule {
    nonisolated let id = ModuleID("screen-change-detection")
    nonisolated let capabilities: Set<Capability> = [.screenChangeDetection]

    private let logger = Logger(subsystem: "com.banti.screen-change-detection", category: "Detection")
    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let differencer: any ScreenFrameDifferencer

    private var subscriptionID: SubscriptionID?
    private var _health: ModuleHealth = .healthy
    private var detectedCount = 0

    init(eventHub: EventHubActor, config: ConfigActor, differencer: (any ScreenFrameDifferencer)? = nil) {
        self.eventHub = eventHub
        self.config = config
        self.differencer = differencer ?? VNScreenFrameDifferencer()
    }

    func start() async throws {
        let threshold = Float(
            (await config.value(for: EnvKey.screenChangeThreshold)).flatMap(Float.init) ?? 0.05
        )

        // Deprecation warning for old time-throttle key
        if await config.value(for: EnvKey.screenDescriptionIntervalS) != nil {
            logger.warning("SCREEN_DESCRIPTION_INTERVAL_S is no longer used — screen descriptions are now change-driven. Remove this key to suppress this warning.")
        }

        subscriptionID = await eventHub.subscribe(ScreenFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleFrame(event, threshold: threshold)
        }
        _health = .healthy
        logger.notice("ScreenChangeDetectionActor started (threshold=\(threshold))")
    }

    func stop() async {
        if let id = subscriptionID {
            await eventHub.unsubscribe(id)
            subscriptionID = nil
        }
    }

    func health() async -> ModuleHealth { _health }

    private func handleFrame(_ event: ScreenFrameEvent, threshold: Float) async {
        do {
            let dist = try await differencer.distance(from: event.jpeg)

            // nil = first frame, no prior reference → always publish
            let shouldPublish = dist.map { $0 >= threshold } ?? true
            guard shouldPublish else { return }

            detectedCount += 1
            _health = .healthy

            let change = ScreenChangeEvent(
                jpeg: event.jpeg,
                changeDistance: dist,
                sequenceNumber: event.sequenceNumber,
                captureTime: event.timestamp
            )
            await eventHub.publish(change)

            if detectedCount == 1 || detectedCount.isMultiple(of: 20) {
                logger.notice("Screen change #\(self.detectedCount), dist=\(dist.map { String(format: "%.3f", $0) } ?? "nil")")
            }
        } catch {
            logger.error("ScreenFrameDifferencer error: \(error.localizedDescription, privacy: .public)")
            _health = .degraded(reason: "ScreenFrameDifferencer failed: \(error.localizedDescription)")
        }
    }
}
