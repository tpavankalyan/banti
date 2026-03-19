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

    // WebSocket connections — one per track (lazily created)
    private var reflexSocket: URLSessionWebSocketTask?
    private var reasoningSocket: URLSessionWebSocketTask?
    // Reflex speaking state (used by finishCurrentSentence)
    private var isSpeakingReflex: Bool = false
    // Queued reasoning audio (played after reflex finishes)
    private var pendingReasoningBuffers: [AVAudioPCMBuffer] = []

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

    public func streamSpeak(_ text: String, track: TrackPriority) async {
        guard isAvailable else {
            logger.log(source: "tts", message: "[info] Cartesia unavailable — would say: \(text)")
            return
        }
        guard let key = apiKey,
              let url = URL(string: "wss://api.cartesia.ai/tts/websocket") else { return }

        // Connect or reuse the track-specific socket
        let socket: URLSessionWebSocketTask
        if track == .reflex {
            if reflexSocket == nil { reflexSocket = connectSocket(url: url, apiKey: key) }
            guard let s = reflexSocket else { return }
            socket = s
            isSpeakingReflex = true
        } else {
            if reasoningSocket == nil { reasoningSocket = connectSocket(url: url, apiKey: key) }
            guard let s = reasoningSocket else { return }
            socket = s
        }

        let body: [String: Any] = [
            "model_id": "sonic-2",
            "transcript": text,
            "voice": ["mode": "id", "id": voiceID],
            "output_format": ["container": "raw", "encoding": "pcm_s16le", "sample_rate": 22050],
        ]
        guard let msgData = try? JSONSerialization.data(withJSONObject: body),
              let msgStr = String(data: msgData, encoding: .utf8) else { return }

        do {
            try await socket.send(.string(msgStr))
        } catch {
            logger.log(source: "tts",
                       message: "[warn] CartesiaSpeaker WS send failed: \(error.localizedDescription)")
            if track == .reflex { reflexSocket = nil; isSpeakingReflex = false }
            else { reasoningSocket = nil }
            return
        }

        // Receive PCM frames until done signal (5s timeout per sentence)
        let deadline = Date().addingTimeInterval(5)
        receiveLoop: while Date() < deadline {
            if Task.isCancelled { break }
            do {
                let message = try await socket.receive()
                switch message {
                case .data(let pcmData):
                    if let buffer = CartesiaSpeaker.makeBuffer(pcmData) {
                        if track == .reflex {
                            playBuffer(buffer)
                        } else {
                            pendingReasoningBuffers.append(buffer)
                            drainReasoningIfReady()
                        }
                    }
                case .string(let txt):
                    if txt.contains("\"done\"") || txt.contains("done") { break receiveLoop }
                @unknown default: break
                }
            } catch {
                logger.log(source: "tts",
                           message: "[warn] CartesiaSpeaker WS receive failed: \(error.localizedDescription)")
                break
            }
        }

        if track == .reflex {
            isSpeakingReflex = false
            drainReasoningIfReady()
        }
    }

    // `async` required: actors release at every `await` point, so `streamSpeak`
    // (suspended on `socket.receive()`) is NOT blocking the actor.
    // Calling `socket.cancel()` here causes the next `receive()` call in
    // `streamSpeak` to throw, safely exiting its loop.
    public func cancelTrack(_ track: TrackPriority) async {
        if track == .reflex {
            reflexSocket?.cancel(with: .normalClosure, reason: nil)
            reflexSocket = nil
            isSpeakingReflex = false
            playerNode.stop()
            if engineStarted { playerNode.play() }
        } else {
            reasoningSocket?.cancel(with: .normalClosure, reason: nil)
            reasoningSocket = nil
            pendingReasoningBuffers.removeAll()
        }
    }

    public func finishCurrentSentence() async {
        var waited = 0.0
        while isSpeakingReflex && waited < 2.0 {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            waited += 0.05
        }
    }

    private func connectSocket(url: URL, apiKey: String) -> URLSessionWebSocketTask {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("2024-06-10", forHTTPHeaderField: "Cartesia-Version")
        let task = session.webSocketTask(with: request)
        task.resume()
        return task
    }

    private func drainReasoningIfReady() {
        guard !isSpeakingReflex, !pendingReasoningBuffers.isEmpty else { return }
        for buffer in pendingReasoningBuffers {
            playBuffer(buffer)
        }
        pendingReasoningBuffers.removeAll()
    }

    // MARK: - Test helpers (internal access for tests in same module)
    func setIsSpeakingForTest(_ value: Bool) { isSpeaking = value }
    var pendingTextForTest: String? { pendingText }
    func setIsSpeakingReflexForTest(_ value: Bool) { isSpeakingReflex = value }
    var isSpeakingReflexForTest: Bool { isSpeakingReflex }
    func addPendingReasoningBufferForTest() {
        if let buf = CartesiaSpeaker.makeBuffer(Data(repeating: 0, count: 200)) {
            pendingReasoningBuffers.append(buf)
        }
    }
    var pendingReasoningBufferCountForTest: Int { pendingReasoningBuffers.count }
}
