// Sources/BantiCore/DeepgramStreamer.swift
import Foundation

public actor DeepgramStreamer {
    private let apiKey: String
    private let context: PerceptionContext
    private let logger: Logger
    private let session: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    private var reconnectDelay: Double = 1.0
    private static let maxReconnectDelay: Double = 30.0

    private var reconnectBuffer: Data = Data()
    static let maxReconnectBufferBytes = 160_000

    private var lastChunkAt: Date?
    private var isConnected = false

    public init(apiKey: String, context: PerceptionContext, logger: Logger, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.context = context
        self.logger = logger
        self.session = session
    }

    // MARK: - Public API

    public func send(chunk: Data) async {
        lastChunkAt = Date()

        if !isConnected {
            connect()
        }

        guard let task = webSocketTask, isConnected else {
            if reconnectBuffer.count + chunk.count <= DeepgramStreamer.maxReconnectBufferBytes {
                reconnectBuffer.append(chunk)
            }
            return
        }

        do {
            try await task.send(.data(chunk))
        } catch {
            logger.log(source: "deepgram", message: "[warn] send failed: \(error.localizedDescription)")
            handleDisconnect()
        }
    }

    // MARK: - KeepAlive (static for testability)

    static func shouldSendKeepAlive(lastChunkAt: Date, now: Date = Date(), silenceThreshold: Double = 8.0) -> Bool {
        now.timeIntervalSince(lastChunkAt) >= silenceThreshold
    }

    // MARK: - Connection management

    private func connect() {
        guard !isConnected else { return }

        let urlString = "wss://api.deepgram.com/v1/listen?model=nova-2&diarize=true&punctuate=true&encoding=linear16&sample_rate=16000&channels=1"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        isConnected = true
        reconnectDelay = 1.0
        logger.log(source: "deepgram", message: "connected")

        startReceiveLoop()
        startKeepAliveMonitor()
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = await self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    await self.handleMessage(message)
                } catch {
                    await self.handleDisconnect()
                    break
                }
            }
        }
    }

    private func startKeepAliveMonitor() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { break }
                if let last = await self.lastChunkAt,
                   DeepgramStreamer.shouldSendKeepAlive(lastChunkAt: last) {
                    await self.sendKeepAlive()
                }
            }
        }
    }

    private func sendKeepAlive() {
        guard let task = webSocketTask, isConnected else { return }
        Task {
            do {
                try await task.send(.string(#"{"type":"KeepAlive"}"#))
            } catch {
                logger.log(source: "deepgram", message: "[warn] KeepAlive failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleDisconnect() {
        guard isConnected else { return }   // prevent double-reconnect from concurrent failures
        isConnected = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        receiveTask?.cancel()
        keepAliveTask?.cancel()

        // Discard reconnect buffer (no replay to avoid duplicate transcripts)
        reconnectBuffer = Data()

        logger.log(source: "deepgram", message: "[warn] disconnected, reconnecting in \(reconnectDelay)s")

        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, DeepgramStreamer.maxReconnectDelay)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.connect()
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let d):      data = d
        @unknown default:       data = nil
        }

        guard let data,
              let state = DeepgramStreamer.parseResponse(data) else { return }

        logger.log(source: "deepgram", message: "[\(state.speakerID.map { "spk:\($0)" } ?? "?")] \(state.transcript)")
        await context.update(.speech(state))
    }

    // MARK: - Response parsing (static + internal for testability)

    static func parseResponse(_ data: Data) -> SpeechState? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isFinal = json["is_final"] as? Bool, isFinal,
              let channel = json["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let first = alternatives.first,
              let transcript = first["transcript"] as? String,
              !transcript.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let confidence = (first["confidence"] as? Double).map { Float($0) } ?? 0.0
        let words = first["words"] as? [[String: Any]]
        let speakerID = words?.first.flatMap { $0["speaker"] as? Int }

        return SpeechState(
            transcript: transcript,
            speakerID: speakerID,
            isFinal: true,
            confidence: confidence,
            updatedAt: Date()
        )
    }
}
