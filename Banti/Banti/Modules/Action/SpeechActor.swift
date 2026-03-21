import Foundation
@preconcurrency import AVFoundation
import os

actor SpeechActor: BantiModule {
    nonisolated let id = ModuleID("speech")
    nonisolated let capabilities: Set<Capability> = [.speech]

    private let logger = Logger(subsystem: "com.banti.speech", category: "Speech")
    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let synthesizeAudioOverride: (@Sendable (String) async throws -> Data)?
    private let playAudioOverride: (@Sendable (Data) async throws -> Void)?

    private var responseSubscriptionID: SubscriptionID?
    private var _health: ModuleHealth = .healthy
    private var currentPlayer: AVAudioPlayer?

    init(
        eventHub: EventHubActor,
        config: ConfigActor,
        synthesizeAudio: (@Sendable (String) async throws -> Data)? = nil,
        playAudio: (@Sendable (Data) async throws -> Void)? = nil
    ) {
        self.eventHub = eventHub
        self.config = config
        self.synthesizeAudioOverride = synthesizeAudio
        self.playAudioOverride = playAudio
    }

    func start() async throws {
        let apiKey = await config.value(for: EnvKey.cartesiaAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let voiceID = await config.value(for: EnvKey.cartesiaVoiceID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty, !voiceID.isEmpty else {
            logger.warning("Cartesia not fully configured — SpeechActor idle; mic/ASR pipeline still runs")
            _health = .degraded(reason: "Cartesia API key or voice ID not set")
            return
        }

        responseSubscriptionID = await eventHub.subscribe(BrainResponseEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleBrainResponse(event)
        }

        _health = .healthy
        logger.notice("SpeechActor started")
    }

    func stop() async {
        currentPlayer?.stop()
        currentPlayer = nil
        if let id = responseSubscriptionID {
            await eventHub.unsubscribe(id)
            responseSubscriptionID = nil
        }
    }

    func health() -> ModuleHealth { _health }

    private func handleBrainResponse(_ event: BrainResponseEvent) async {
        await eventHub.publish(SpeechPlaybackEvent(isPlaying: true))

        do {
            let audioData: Data
            if let synthesizeAudioOverride {
                audioData = try await synthesizeAudioOverride(event.text)
            } else {
                audioData = try await synthesize(text: event.text)
            }

            if let playAudioOverride {
                try await playAudioOverride(audioData)
            } else {
                try await playAudio(audioData)
            }

            logger.notice("Finished speaking")
        } catch {
            logger.error("Speech error: \(error.localizedDescription, privacy: .public)")
            _health = .degraded(reason: "speech playback failed")
        }

        await eventHub.publish(SpeechPlaybackEvent(isPlaying: false))
    }

    private func playAudio(_ audioData: Data) async throws {
        let player = try AVAudioPlayer(data: audioData)
        currentPlayer = player
        player.play()
        try? await Task.sleep(for: .seconds(player.duration + 0.2))
        currentPlayer = nil
    }

    private func synthesize(text: String) async throws -> Data {
        let apiKey = try await config.require(EnvKey.cartesiaAPIKey)
        let voiceID = try await config.require(EnvKey.cartesiaVoiceID)
        let modelID = (await config.value(for: EnvKey.cartesiaModel)) ?? "sonic-2"

        let url = URL(string: "https://api.cartesia.ai/tts/bytes")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("2024-06-10", forHTTPHeaderField: "Cartesia-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model_id": modelID,
            "transcript": text,
            "voice": [
                "mode": "id",
                "id": voiceID,
            ],
            "output_format": [
                "container": "wav",
                "encoding": "pcm_s16le",
                "sample_rate": 44100,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ConfigError(message: "Invalid response from Cartesia")
        }
        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw ConfigError(message: "Cartesia \(http.statusCode): \(errorBody)")
        }

        return data
    }
}
