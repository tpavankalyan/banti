// Banti/Banti/Modules/Perception/Camera/SceneChangeDetectionActor.swift
import Foundation
import os

actor SceneChangeDetectionActor: BantiModule {
    nonisolated let id = ModuleID("scene-change-detection")
    nonisolated let capabilities: Set<Capability> = [.sceneChangeDetection]

    private let logger = Logger(subsystem: "com.banti.scene-change-detection", category: "Detection")
    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let differencer: any FrameDifferencer

    private var subscriptionID: SubscriptionID?
    private var _health: ModuleHealth = .healthy
    private var detectedCount = 0

    init(eventHub: EventHubActor, config: ConfigActor, differencer: (any FrameDifferencer)? = nil) {
        self.eventHub = eventHub
        self.config = config
        self.differencer = differencer ?? VNFrameDifferencer()
    }

    func start() async throws {
        let threshold = Float(
            (await config.value(for: EnvKey.sceneChangeThreshold)).flatMap(Float.init) ?? 0.15
        )

        subscriptionID = await eventHub.subscribe(CameraFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleFrame(event, threshold: threshold)
        }
        _health = .healthy
        logger.notice("SceneChangeDetectionActor started (threshold=\(threshold))")
    }

    func stop() async {
        if let id = subscriptionID {
            await eventHub.unsubscribe(id)
            subscriptionID = nil
        }
    }

    func health() async -> ModuleHealth { _health }

    private func handleFrame(_ event: CameraFrameEvent, threshold: Float) async {
        do {
            let dist = try await differencer.distance(from: event.jpeg)

            // nil = first frame, no prior reference → always publish
            let shouldPublish = dist.map { $0 >= threshold } ?? true
            guard shouldPublish else { return }

            detectedCount += 1
            _health = .healthy

            let change = SceneChangeEvent(
                jpeg: event.jpeg,
                changeDistance: dist ?? 0,
                sequenceNumber: event.sequenceNumber,
                captureTime: event.timestamp
            )
            await eventHub.publish(change)

            if detectedCount == 1 || detectedCount.isMultiple(of: 20) {
                logger.notice("Scene change #\(self.detectedCount), dist=\(dist ?? 0, format: .fixed(precision: 3))")
            }
        } catch {
            logger.error("FrameDifferencer error: \(error.localizedDescription, privacy: .public)")
            _health = .degraded(reason: "FrameDifferencer failed: \(error.localizedDescription)")
        }
    }
}
