import Foundation
import os

actor DeepgramStreamingActor: PerceptionModule {
    nonisolated let id = ModuleID("deepgram-asr")
    nonisolated let capabilities: Set<Capability> = [.transcription, .diarization]

    private let logger = Logger(subsystem: "com.banti.deepgram-asr", category: "Deepgram")
    private let eventHub: EventHubActor
    private let config: ConfigActor
    private let replayProvider: (any AudioFrameReplayProvider)?
    private var webSocketTask: URLSessionWebSocketTask?
    private var subscriptionID: SubscriptionID?
    private var receiveTask: Task<Void, Never>?
    private var _health: ModuleHealth = .healthy
    private var lastSentSequence: UInt64 = 0
    private var sentFrameCount = 0
    private var receivedTranscriptCount = 0
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let reconnectDelays: [TimeInterval] = [1, 2, 4, 8, 16]

    private var parseErrors: [Date] = []
    private var parseTimes: [Date] = []
    private let errorWindowSeconds: TimeInterval = 30
    private let errorRateThreshold: Double = 0.10
    private var isReconnecting = false

    init(eventHub: EventHubActor, config: ConfigActor,
         replayProvider: (any AudioFrameReplayProvider)? = nil) {
        self.eventHub = eventHub
        self.config = config
        self.replayProvider = replayProvider
    }

    func start() async throws {
        let apiKey = try await config.require(EnvKey.deepgramAPIKey)
        try await connect(apiKey: apiKey)

        subscriptionID = await eventHub.subscribe(AudioFrameEvent.self) { [weak self] event in
            guard let self else { return }
            await self.sendAudio(event)
        }
    }

    func stop() async {
        if let subID = subscriptionID {
            await eventHub.unsubscribe(subID)
            subscriptionID = nil
        }
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    func health() -> ModuleHealth { _health }

    private func connect(apiKey: String) async throws {
        let model = (await config.value(for: EnvKey.deepgramModel)) ?? "nova-2"
        let language = (await config.value(for: EnvKey.deepgramLanguage)) ?? "en"

        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()
        self.webSocketTask = task
        _health = .healthy
        reconnectAttempts = 0
        logger.notice("Connected to Deepgram (model=\(model), lang=\(language))")

        startReceiving()
    }

    private func sendAudio(_ event: AudioFrameEvent) {
        guard let ws = webSocketTask else { return }
        lastSentSequence = event.sequenceNumber
        sentFrameCount += 1
        let message = URLSessionWebSocketTask.Message.data(event.audioData)
        ws.send(message) { [weak self] error in
            if let error {
                Task { [weak self] in
                    guard let self else { return }
                    await self.handleSendError(error)
                }
            }
        }
        if sentFrameCount == 1 || sentFrameCount.isMultiple(of: 50) {
            logger.notice("Sent \(self.sentFrameCount) audio frames to Deepgram")
        }
    }

    private func handleSendError(_ error: Error) {
        logger.error("WebSocket send error: \(error.localizedDescription)")
        _health = .degraded(reason: "send error")
        Task { [weak self] in await self?.attemptReconnect() }
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let ws = await self.webSocketTask else { return }
                do {
                    let message = try await ws.receive()
                    await self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        await self.handleReceiveError(error)
                    }
                    return
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8) else { return }

        recordParse()

        do {
            let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
            guard let channel = response.channel?.alternatives?.first else { return }
            let isFinal = response.isFinal ?? false
            let transcript = channel.transcript ?? ""
            let words = channel.words ?? []

            receivedTranscriptCount += 1
            if receivedTranscriptCount == 1 || receivedTranscriptCount.isMultiple(of: 10) {
                logger.notice("Deepgram #\(self.receivedTranscriptCount) final=\(isFinal) words=\(words.count) transcript=\(transcript.prefix(80), privacy: .public)")
            }

            guard !transcript.isEmpty else { return }

            let speakerIndex = words.first?.speaker
            let startTime = words.first?.start ?? response.start ?? 0
            let endTime = words.last?.end ?? ((response.start ?? 0) + (response.duration ?? 0))
            let confidence = channel.confidence ?? words.first?.confidence ?? 0

            let event = RawTranscriptEvent(
                text: transcript,
                speakerIndex: speakerIndex,
                confidence: confidence,
                isFinal: isFinal,
                audioStartTime: startTime,
                audioEndTime: endTime
            )
            await eventHub.publish(event)
        } catch {
            logger.warning("Failed to decode Deepgram response: \(error.localizedDescription)")
            recordParseError()
        }
    }

    private func recordParse() {
        parseTimes.append(Date())
        pruneWindow()
    }

    private func recordParseError() {
        parseErrors.append(Date())
        pruneWindow()
        let errorRate = Double(parseErrors.count) / Double(max(parseTimes.count, 1))
        if errorRate > errorRateThreshold {
            _health = .degraded(reason: "parse error rate \(Int(errorRate * 100))%")
        }
    }

    private func pruneWindow() {
        let now = Date()
        parseErrors.removeAll { now.timeIntervalSince($0) > errorWindowSeconds }
        parseTimes.removeAll { now.timeIntervalSince($0) > errorWindowSeconds }
    }

    private func handleReceiveError(_ error: Error) {
        let nsError = error as NSError
        if nsError.code == 401 || nsError.code == 1008 {
            _health = .failed(error: ConfigError(message: "Deepgram auth rejected"))
            logger.error("Auth failure — not retrying")
            return
        }
        logger.error("WebSocket receive error: \(error.localizedDescription)")
        _health = .degraded(reason: "connection lost")
        Task { [weak self] in await self?.attemptReconnect() }
    }

    private func attemptReconnect() async {
        guard !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }

        guard reconnectAttempts < maxReconnectAttempts else {
            _health = .failed(error: ConfigError(message: "Max reconnect attempts exceeded"))
            return
        }
        let delay = reconnectDelays[min(reconnectAttempts, reconnectDelays.count - 1)]
        reconnectAttempts += 1
        logger.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempts))")
        try? await Task.sleep(for: .seconds(delay))

        let lastSeq = lastSentSequence
        webSocketTask?.cancel()
        webSocketTask = nil
        receiveTask?.cancel()

        guard let apiKey = try? await config.require(EnvKey.deepgramAPIKey) else {
            _health = .failed(error: ConfigError(message: "Missing API key on reconnect"))
            return
        }
        try? await connect(apiKey: apiKey)

        if let provider = replayProvider {
            let frames = await provider.replayFrames(after: lastSeq)
            for frame in frames {
                let event = AudioFrameEvent(
                    audioData: frame.data,
                    sequenceNumber: frame.seq
                )
                sendAudio(event)
            }
            logger.info("Replayed \(frames.count) buffered frames after reconnect")
        }
    }
}

// MARK: - Deepgram JSON Models

struct DeepgramResponse: Decodable, Sendable {
    let channel: DeepgramChannel?
    let isFinal: Bool?
    let start: Double?
    let duration: Double?

    enum CodingKeys: String, CodingKey {
        case channel
        case isFinal = "is_final"
        case start, duration
    }
}

struct DeepgramChannel: Decodable, Sendable {
    let alternatives: [DeepgramAlternative]?
}

struct DeepgramAlternative: Decodable, Sendable {
    let transcript: String?
    let confidence: Double?
    let words: [DeepgramWord]?
}

struct DeepgramWord: Decodable, Sendable {
    let word: String
    let start: Double
    let end: Double
    let confidence: Double
    let speaker: Int?
    let punctuatedWord: String?

    enum CodingKeys: String, CodingKey {
        case word, start, end, confidence, speaker
        case punctuatedWord = "punctuated_word"
    }
}
