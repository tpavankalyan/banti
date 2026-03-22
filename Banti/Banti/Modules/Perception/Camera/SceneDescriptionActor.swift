import Foundation
import os

actor SceneDescriptionActor: BantiModule {
    nonisolated let id = ModuleID("scene-description")
    nonisolated let capabilities: Set<Capability> = [.sceneDescription]

    private let logger = Logger(subsystem: "com.banti.scene-description", category: "Scene")
    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let overrideProvider: (any VisionProvider)?
    private let replayProvider: (any CameraFrameReplayProvider)?

    private var subscriptionID: SubscriptionID?
    private var _health: ModuleHealth = .healthy
    private var describedCount = 0

    init(
        eventHub: EventHubActor,
        config: ConfigActor,
        replayProvider: (any CameraFrameReplayProvider)? = nil,
        provider: (any VisionProvider)? = nil
    ) {
        self.eventHub = eventHub
        self.config = config
        self.replayProvider = replayProvider
        self.overrideProvider = provider
    }

    func start() async throws {
        let provider = try await buildProvider()
        let prompt = (await config.value(for: EnvKey.sceneDescriptionPrompt))
            ?? "Describe the visual scene concisely, focusing on people, objects, and activities."

        subscriptionID = await eventHub.subscribe(SceneChangeEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleChange(event, provider: provider, prompt: prompt)
        }

        _health = .healthy
        logger.notice("SceneDescriptionActor started (change-driven)")
    }

    func stop() async {
        if let id = subscriptionID {
            await eventHub.unsubscribe(id)
            subscriptionID = nil
        }
    }

    func health() async -> ModuleHealth { _health }

    private func handleChange(
        _ event: SceneChangeEvent,
        provider: any VisionProvider,
        prompt: String
    ) async {
        do {
            let description = try await provider.describe(jpeg: event.jpeg, prompt: prompt)
            let responseTime = Date()

            describedCount += 1
            _health = .healthy

            let sceneEvent = SceneDescriptionEvent(
                text: description,
                captureTime: event.captureTime,
                responseTime: responseTime,
                changeDistance: event.changeDistance
            )
            await eventHub.publish(sceneEvent)

            if describedCount == 1 || describedCount.isMultiple(of: 10) {
                logger.notice("Published scene desc #\(self.describedCount): \(description.prefix(60), privacy: .public)")
            }
        } catch {
            logger.error("VisionProvider error: \(error.localizedDescription, privacy: .public)")
            _health = .degraded(reason: "VLM call failed: \(error.localizedDescription)")
        }
    }

    private func buildProvider() async throws -> any VisionProvider {
        if let override = overrideProvider { return override }

        let selected = ((await config.value(for: EnvKey.visionProvider)) ?? "claude")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch selected {
        case "claude":
            let key = try await config.require(EnvKey.anthropicAPIKey)
            let model = (await config.value(for: EnvKey.anthropicVisionModel)) ?? ClaudeVisionProvider.defaultModel
            logger.notice("Scene vision using Claude (\(model, privacy: .public))")
            return ClaudeVisionProvider(apiKey: key, model: model)

        default:
            throw VisionError("Unknown VISION_PROVIDER: \(selected). Supported: claude")
        }
    }
}
