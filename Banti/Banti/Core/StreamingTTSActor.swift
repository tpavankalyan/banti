// Banti/Banti/Core/StreamingTTSActor.swift
import Foundation
import AVFoundation
import os

// MARK: - Protocol

protocol CartesiaWebSocketProvider: Sendable {
    func connect() async throws -> AsyncThrowingStream<Data, Error>
    func send(text: String, contextID: String, continuing: Bool) async throws
    func disconnect() async
}

// MARK: - Real provider
// Must be an actor (not struct) so wsTask is shared between connect() and send().

actor RealCartesiaWSProvider: CartesiaWebSocketProvider {
    let apiKey: String
    let voiceID: String
    let cartesiaVersion: String

    static let defaultVoiceID = "694f9389-aac1-45b6-b726-9d9369183238"
    private static let modelID = "sonic-3"

    private var wsTask: URLSessionWebSocketTask?

    init(apiKey: String, voiceID: String = RealCartesiaWSProvider.defaultVoiceID,
         cartesiaVersion: String) {
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.cartesiaVersion = cartesiaVersion
    }

    private func makeURL() -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.cartesia.ai"
        components.path = "/tts/websocket"
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "cartesia_version", value: cartesiaVersion)
        ]
        return components.url!  // Safe: scheme/host/path are hardcoded literals, only query values are user-provided
    }

    func connect() async throws -> AsyncThrowingStream<Data, Error> {
        let task = URLSession.shared.webSocketTask(with: makeURL())
        task.resume()
        wsTask = task  // store so send() can use the same task

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    while true {
                        let msg = try await task.receive()
                        switch msg {
                        case .string(let s):
                            guard let data = s.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                            else { continue }
                            let type_ = json["type"] as? String ?? ""
                            if type_ == "chunk", let b64 = json["data"] as? String,
                               let pcm = Data(base64Encoded: b64) {
                                continuation.yield(pcm)
                            } else if type_ == "done" {
                                // utterance complete — keep connection open for next chunk
                            }
                        case .data: break
                        @unknown default: break
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func send(text: String, contextID: String, continuing: Bool) async throws {
        guard let task = wsTask else { throw URLError(.notConnectedToInternet) }
        let payload: [String: Any] = [
            "context_id": contextID,
            "model_id": Self.modelID,
            "transcript": text,
            "voice": ["mode": "id", "id": voiceID],
            "output_format": ["container": "raw", "encoding": "pcm_f32le", "sample_rate": 44100],
            "continue": continuing,
            "add_timestamps": false
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await task.send(.string(String(data: data, encoding: .utf8)!))
    }

    func disconnect() async {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }
}

// MARK: - Actor

actor StreamingTTSActor: BantiModule {
    nonisolated let id = ModuleID("streaming-tts")
    nonisolated let capabilities: Set<Capability> = [.speech]

    private let eventHub: EventHubActor
    private var wsProvider: any CartesiaWebSocketProvider  // var so start() can inject real API key
    private let config: ConfigActor?
    private var subscriptionIDs: [SubscriptionID] = []
    private var _health: ModuleHealth = .healthy
    private let logger = Logger(subsystem: "com.banti.tts", category: "Streaming")

    // Epoch — SET from InterruptEvent.epoch (never incremented here)
    private var epoch: Int = 0

    // Current utterance context
    private var currentContextID: String?

    // Task that owns the WebSocket audio loop; cancelled in stop()
    private var connectTask: Task<Void, Never>?

    // Set to true in stop() so handleDisconnect()'s retry loop can exit even
    // when running in an event-handler Task (not connectTask) where Task.isCancelled won't fire.
    private var isStopped = false

    // Audio engine
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    // 44100 Hz matches the Cartesia output_format sample_rate in RealCartesiaWSProvider.send()
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 44100, channels: 1, interleaved: false)!

    // Reconnect config
    private let reconnectBaseDelay: TimeInterval
    private let maxReconnectDelay: TimeInterval

    init(eventHub: EventHubActor,
         wsProvider: any CartesiaWebSocketProvider,
         reconnectBaseDelay: TimeInterval = 1.0,
         maxReconnectDelay: TimeInterval = 30.0) {
        self.eventHub = eventHub
        self.wsProvider = wsProvider
        self.config = nil
        self.reconnectBaseDelay = reconnectBaseDelay
        self.maxReconnectDelay = maxReconnectDelay
    }

    init(eventHub: EventHubActor, config: ConfigActor,
         reconnectBaseDelay: TimeInterval = 1.0,
         maxReconnectDelay: TimeInterval = 30.0) {
        self.eventHub = eventHub
        self.wsProvider = RealCartesiaWSProvider(
            apiKey: "", voiceID: RealCartesiaWSProvider.defaultVoiceID,
            cartesiaVersion: "2025-04-16") // real key injected at start()
        self.config = config
        self.reconnectBaseDelay = reconnectBaseDelay
        self.maxReconnectDelay = maxReconnectDelay
    }

    func start() async throws {
        // Inject real Cartesia API key from config
        if let cfg = config {
            let apiKey = try await cfg.require(EnvKey.cartesiaAPIKey)
            wsProvider = RealCartesiaWSProvider(apiKey: apiKey,
                                                voiceID: RealCartesiaWSProvider.defaultVoiceID,
                                                cartesiaVersion: "2025-04-16")
        }

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
        try? audioEngine.start()

        subscriptionIDs.append(await eventHub.subscribe(SpeakChunkEvent.self) { [weak self] e in
            await self?.handle(e)
        })
        subscriptionIDs.append(await eventHub.subscribe(InterruptEvent.self) { [weak self] e in
            await self?.handle(e)
        })

        // Connect to Cartesia and begin streaming PCM audio
        connectTask = Task { await connectAndListen() }
        _health = .healthy
    }

    // MARK: - WebSocket audio loop

    /// Connects to Cartesia and drains PCM audio chunks into scheduleAudio.
    /// On failure sets health degraded and returns — handleDisconnect() handles retry.
    private func connectAndListen() async {
        do {
            let stream = try await wsProvider.connect()
            _health = .healthy
            for try await pcmData in stream {
                scheduleAudio(pcmData, epoch: self.epoch)
            }
        } catch {
            guard !Task.isCancelled else { return }
            _health = .degraded(reason: "Cartesia WebSocket: \(error.localizedDescription)")
            currentContextID = nil
        }
    }

    func stop() async {
        isStopped = true
        connectTask?.cancel()
        connectTask = nil
        for s in subscriptionIDs { await eventHub.unsubscribe(s) }
        subscriptionIDs.removeAll()
        playerNode.stop()
        audioEngine.stop()
        await wsProvider.disconnect()
    }

    func health() async -> ModuleHealth { _health }

    // MARK: - Event handlers

    private func handle(_ event: SpeakChunkEvent) async {
        guard event.epoch == self.epoch else { return }

        if currentContextID == nil {
            currentContextID = UUID().uuidString
        }
        guard let ctxID = currentContextID else { return }

        do {
            try await wsProvider.send(text: event.text, contextID: ctxID, continuing: true)
        } catch {
            logger.warning("Cartesia send failed: \(error.localizedDescription, privacy: .public)")
            await handleDisconnect()
        }
    }

    private func handle(_ event: InterruptEvent) async {
        // SET epoch from the authoritative source (CognitiveCoreActor)
        self.epoch = event.epoch

        // Flush Cartesia context — always send continue:false to signal end of utterance
        let ctxID = currentContextID ?? UUID().uuidString
        try? await wsProvider.send(text: "", contextID: ctxID, continuing: false)
        currentContextID = nil

        // Stop audio
        playerNode.stop()
    }

    // MARK: - Audio scheduling (called when Cartesia sends PCM back)

    private func scheduleAudio(_ pcmData: Data, epoch: Int) {
        guard epoch == self.epoch else { return }
        guard let buffer = pcmData.toAVAudioPCMBuffer(format: audioFormat) else { return }
        playerNode.scheduleBuffer(buffer)
        if !playerNode.isPlaying { playerNode.play() }
    }

    // MARK: - Reconnect

    private func handleDisconnect() async {
        _health = .degraded(reason: "Cartesia WebSocket disconnected")
        currentContextID = nil

        var delay = reconnectBaseDelay
        while true {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled && !isStopped else { return }
            do {
                let stream = try await wsProvider.connect()
                _health = .healthy
                logger.notice("Cartesia reconnected")
                for try await pcmData in stream {
                    scheduleAudio(pcmData, epoch: self.epoch)
                }
                return // stream closed cleanly
            } catch {
                delay = min(delay * 2, maxReconnectDelay)
                logger.warning("Cartesia reconnect failed, retry in \(delay)s")
            }
        }
    }
}

// MARK: - Data → AVAudioPCMBuffer

private extension Data {
    func toAVAudioPCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(count / MemoryLayout<Float32>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount
        self.withUnsafeBytes { ptr in
            if let src = ptr.bindMemory(to: Float32.self).baseAddress,
               let dst = buffer.floatChannelData?[0] {
                dst.update(from: src, count: Int(frameCount))
            }
        }
        return buffer
    }
}
