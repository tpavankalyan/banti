// Sources/BantiCore/CartesiaSpeaker.swift
import Foundation
import AVFoundation

public actor CartesiaSpeaker {
    private let apiKey: String?
    private let voiceID: String
    private let logger: Logger
    private let session: URLSession

    // Playback state
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var engineStarted = false

    // Queue: at most one pending text (replaces previous if still pending)
    private var pendingText: String?
    private var isSpeaking: Bool = false

    public var isAvailable: Bool { apiKey != nil }

    public init(logger: Logger,
                apiKey: String? = ProcessInfo.processInfo.environment["CARTESIA_API_KEY"],
                voiceID: String = ProcessInfo.processInfo.environment["CARTESIA_VOICE_ID"]
                             ?? "a0e99841-438c-4a64-b679-ae501e7d6091",
                session: URLSession = .shared) {
        self.logger = logger
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.session = session
    }

    public func speak(_ text: String) {
        guard isAvailable else {
            logger.log(source: "tts", message: "[info] Cartesia unavailable — would say: \(text)")
            return
        }
        if isSpeaking {
            pendingText = text
            return
        }
        isSpeaking = true
        Task { await playSpeech(text) }
    }

    private func playSpeech(_ text: String) async {
        defer {
            isSpeaking = false
            if let next = pendingText {
                pendingText = nil
                speak(next)
            }
        }

        guard let key = apiKey,
              let url = URL(string: "https://api.cartesia.ai/tts/bytes") else { return }

        let body: [String: Any] = [
            "model_id": "sonic-2",
            "transcript": text,
            "voice": ["mode": "id", "id": voiceID],
            "output_format": ["container": "raw", "encoding": "pcm_s16le", "sample_rate": 22050]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        request.setValue("2024-06-10", forHTTPHeaderField: "Cartesia-Version")

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                logger.log(source: "tts", message: "[warn] Cartesia HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            guard let buffer = CartesiaSpeaker.makeBuffer(data) else {
                logger.log(source: "tts", message: "[warn] CartesiaSpeaker: failed to build PCM buffer")
                return
            }
            playBuffer(buffer)
        } catch {
            logger.log(source: "tts", message: "[warn] CartesiaSpeaker: \(error.localizedDescription)")
        }
    }

    private func playBuffer(_ buffer: AVAudioPCMBuffer) {
        if !engineStarted {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: buffer.format)
            try? engine.start()
            engineStarted = true
        }
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in }
        if !playerNode.isPlaying { playerNode.play() }
    }

    /// Construct an AVAudioPCMBuffer from raw pcm_s16le mono bytes at 22050 Hz.
    public static func makeBuffer(_ data: Data, sampleRate: Double = 22050) -> AVAudioPCMBuffer? {
        guard !data.isEmpty else { return nil }
        let frameCount = AVAudioFrameCount(data.count / 2)  // Int16 = 2 bytes per frame
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { ptr in
            guard let src = ptr.bindMemory(to: Int16.self).baseAddress,
                  let dst = buffer.int16ChannelData?[0] else { return }
            dst.update(from: src, count: Int(frameCount))
        }
        return buffer
    }

    // MARK: - Test helpers (internal access for tests in same module)
    func setIsSpeakingForTest(_ value: Bool) { isSpeaking = value }
    var pendingTextForTest: String? { pendingText }
}
