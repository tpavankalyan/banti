// Sources/BantiCore/HumeVoiceAnalyzer.swift
import Foundation

public final class HumeVoiceAnalyzer {
    private let apiKey: String
    private let context: PerceptionContext
    private let logger: Logger
    private let session: URLSession

    public init(apiKey: String, context: PerceptionContext, logger: Logger, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.context = context
        self.logger = logger
        self.session = session
    }

    /// Analyze a PCM segment: wrap in WAV, send to Hume, return result.
    /// Returns nil if pcmData is empty or the API call fails.
    public func analyze(pcmData: Data) async -> VoiceEmotionState? {
        guard !pcmData.isEmpty else { return nil }
        let wavData = HumeVoiceAnalyzer.makeWAV(pcmData: pcmData)
        return await callHumeAPI(wavData: wavData)
    }

    // MARK: - WAV header construction (internal for testability)

    static func makeWAV(pcmData: Data,
                        sampleRate: UInt32 = 16_000,
                        channels: UInt16 = 1,
                        bitsPerSample: UInt16 = 16) -> Data {
        let dataSize   = UInt32(pcmData.count)
        let byteRate   = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var header = Data(capacity: 44)
        header.append(contentsOf: "RIFF".utf8)
        header.appendLE(dataSize + 36)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendLE(UInt32(16))
        header.appendLE(UInt16(1))
        header.appendLE(channels)
        header.appendLE(sampleRate)
        header.appendLE(byteRate)
        header.appendLE(blockAlign)
        header.appendLE(bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.appendLE(dataSize)
        return header + pcmData
    }

    // MARK: - Response parsing (internal for testability)

    static func parseResponse(_ data: Data) -> VoiceEmotionState? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prosody = json["prosody"] as? [String: Any],
              let predictions = prosody["predictions"] as? [[String: Any]],
              let first = predictions.first,
              let emotions = first["emotions"] as? [[String: Any]],
              !emotions.isEmpty else { return nil }

        let parsed = emotions.compactMap { e -> (label: String, score: Float)? in
            guard let name = e["name"] as? String,
                  let score = e["score"] as? Double else { return nil }
            return (label: name, score: Float(score))
        }
        guard !parsed.isEmpty else { return nil }
        return VoiceEmotionState(emotions: parsed, updatedAt: Date())
    }

    // MARK: - API call (connect-per-segment, matches HumeEmotionAnalyzer pattern)

    private func callHumeAPI(wavData: Data) async -> VoiceEmotionState? {
        guard let url = URL(string: "wss://api.hume.ai/v0/stream/models?api_key=\(apiKey)") else { return nil }

        let body: [String: Any] = [
            "models": ["prosody": [:]],
            "data":   wavData.base64EncodedString()
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let bodyString = String(data: bodyData, encoding: .utf8) else { return nil }

        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        do {
            try await task.send(.string(bodyString))
            let message = try await withTimeout(seconds: 10) {
                try await task.receive()
            }
            switch message {
            case .string(let text): return HumeVoiceAnalyzer.parseResponse(text.data(using: .utf8) ?? Data())
            case .data(let data):   return HumeVoiceAnalyzer.parseResponse(data)
            @unknown default:       return nil
            }
        } catch {
            logger.log(source: "hume-voice", message: "[warn] \(error.localizedDescription)")
            return nil
        }
    }

    private func withTimeout<T: Sendable>(seconds: Double,
                                          operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Data helpers for little-endian encoding

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}
