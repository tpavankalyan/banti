import Foundation
import AVFoundation
import os

// MARK: - Provider protocol

/// Abstracts the Cartesia HTTP call so tests can inject a stub.
protocol TTSProvider: Sendable {
    func synthesize(text: String) async throws -> Data
}

// MARK: - Real Cartesia provider

/// Calls the Cartesia /tts/bytes endpoint and returns raw WAV data.
struct CartesiaTTSProvider: TTSProvider {
    let apiKey: String
    let voiceID: String

    static let defaultVoiceID = "694f9389-aac1-45b6-b726-9d9369183238"
    private static let model = "sonic-3"
    private static let apiVersion = "2025-04-16"

    func synthesize(text: String) async throws -> Data {
        let url = URL(string: "https://api.cartesia.ai/tts/bytes")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Cartesia-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model_id": Self.model,
            "transcript": text,
            "voice": ["mode": "id", "id": voiceID],
            "output_format": [
                "container": "wav",
                "encoding": "pcm_f32le",
                "sample_rate": 44100
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TTSError("Cartesia returned \(code)")
        }
        return data
    }
}

struct TTSError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Actor

/// Subscribes to AgentResponseEvent, synthesizes speech via Cartesia, and plays it.
/// TTS failures are logged but never degrade health — TTS is best-effort output.
actor TTSActor: BantiModule {
    nonisolated let id = ModuleID("tts")
    nonisolated let capabilities: Set<Capability> = [.speech]

    private let eventHub: EventHubActor
    private var ttsProvider: (any TTSProvider)?
    private let config: ConfigActor?
    private var subscriptionIDs: [SubscriptionID] = []
    private var _health: ModuleHealth = .healthy
    private var currentPlayer: AVAudioPlayer?
    private let logger = Logger(subsystem: "com.banti.tts", category: "TTS")

    /// Inject a provider directly — used by tests.
    init(eventHub: EventHubActor, ttsProvider: any TTSProvider) {
        self.eventHub = eventHub
        self.ttsProvider = ttsProvider
        self.config = nil
    }

    /// Read API key and voice ID from config at start() time — used by BantiApp.
    init(eventHub: EventHubActor, config: ConfigActor) {
        self.eventHub = eventHub
        self.ttsProvider = nil
        self.config = config
    }

    func start() async throws {
        if ttsProvider == nil, let cfg = config {
            let apiKey = try await cfg.require(EnvKey.cartesiaAPIKey)
            let voiceID = await cfg.value(for: EnvKey.cartesiaVoiceID)
                ?? CartesiaTTSProvider.defaultVoiceID
            ttsProvider = CartesiaTTSProvider(apiKey: apiKey, voiceID: voiceID)
        }
        guard ttsProvider != nil else {
            throw TTSError("No TTS provider configured")
        }
        subscriptionIDs.append(await eventHub.subscribe(AgentResponseEvent.self) { [weak self] event in
            await self?.handle(event)
        })
        _health = .healthy
    }

    func stop() async {
        for subID in subscriptionIDs {
            await eventHub.unsubscribe(subID)
        }
        subscriptionIDs.removeAll()
        currentPlayer?.stop()
        currentPlayer = nil
    }

    func health() async -> ModuleHealth { _health }

    // MARK: - Private

    private func handle(_ event: AgentResponseEvent) async {
        guard let provider = ttsProvider else { return }
        do {
            let data = try await provider.synthesize(text: event.responseText)
            let player = try AVAudioPlayer(data: data)
            currentPlayer = player
            player.play()
            logger.debug("TTS playing \(data.count) bytes")
        } catch {
            logger.warning("TTS failed: \(error.localizedDescription, privacy: .public)")
            // Non-fatal — TTS is best-effort
        }
    }
}
