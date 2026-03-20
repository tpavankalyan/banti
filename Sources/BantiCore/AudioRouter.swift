// Sources/BantiCore/AudioRouter.swift
import Foundation

public actor AudioRouter: AudioChunkDispatcher {
    private let context: PerceptionContext
    private let logger: Logger

    private var deepgram: DeepgramStreamer?
    private var hume: HumeVoiceAnalyzer?
    private var bus: EventBus?
    private var audioCortex: AudioCortex?
    private var didLogDeepgramStreaming = false

    public func setBus(_ bus: EventBus) {
        self.bus = bus
    }

    public func setAudioCortex(_ cortex: AudioCortex) {
        self.audioCortex = cortex
    }
    private var humeBuffer: Data = Data()
    private var pcmRingBuffer: Data = Data()
    /// 3 seconds at 16kHz × 1 channel × 2 bytes/sample = 96,000 bytes.
    static let humeFlushThreshold = 96_000
    /// 5 seconds at 16kHz × 1 channel × 2 bytes/sample = 160,000 bytes.
    public static let pcmRingBufferMaxBytes = 160_000

    public init(context: PerceptionContext, logger: Logger) {
        self.context = context
        self.logger = logger
    }

    // MARK: - Configuration

    public func configure() {
        let env = ProcessInfo.processInfo.environment
        configureWith(
            deepgramKey: env["DEEPGRAM_API_KEY"],
            humeKey: env["HUME_API_KEY"]
        )
    }

    public func configureWith(deepgramKey: String?, humeKey: String?) {
        if let key = deepgramKey {
            deepgram = DeepgramStreamer(apiKey: key, logger: logger)
        } else {
            logger.log(source: "audio", message: "[warn] DEEPGRAM_API_KEY missing — speech transcription disabled")
        }
        if let key = humeKey {
            hume = HumeVoiceAnalyzer(apiKey: key, context: context, logger: logger)
        } else {
            logger.log(source: "audio", message: "[warn] HUME_API_KEY missing — vocal emotion disabled")
        }
    }

    public func setTranscriptCallback(_ callback: @escaping @Sendable (String) async -> Void) async {
        let capturedBus = bus
        await deepgram?.setTranscriptCallback { [self] transcript in
            // Efference copy gate: suppress if banti is currently speaking
            if let cortex = await self.audioCortex, await cortex.isSuppressed() {
                self.logger.log(
                    source: "deepgram",
                    message: "[debug] final transcript suppressed while voice gate is active: \(transcript)"
                )
                return
            }
            await callback(transcript)
            if let b = capturedBus {
                let event = BantiEvent(
                    source: "audio_cortex",
                    topic: "sensor.audio",
                    surprise: 1.0,
                    payload: .speechDetected(SpeechPayload(transcript: transcript, speakerID: nil))
                )
                await b.publish(event, topic: "sensor.audio")
            }
        }
    }

    // MARK: - Dispatch (AudioChunkDispatcher)

    public func appendToPCMRingBuffer(_ chunk: Data) {
        pcmRingBuffer.append(chunk)
        if pcmRingBuffer.count > AudioRouter.pcmRingBufferMaxBytes {
            let excess = pcmRingBuffer.count - AudioRouter.pcmRingBufferMaxBytes
            pcmRingBuffer.removeFirst(excess)
        }
    }

    public func readPCMRingBuffer() -> Data {
        return pcmRingBuffer
    }

    public func dispatch(pcmChunk: Data) async {
        // Stream every chunk to Deepgram (direct await preserves chunk ordering)
        if let streamer = deepgram {
            if !didLogDeepgramStreaming {
                didLogDeepgramStreaming = true
                logger.log(source: "audio", message: "[debug] forwarding microphone audio to Deepgram")
            }
            await streamer.send(chunk: pcmChunk)
        }
        appendToPCMRingBuffer(pcmChunk)

        humeBuffer.append(pcmChunk)
        if humeBuffer.count >= AudioRouter.humeFlushThreshold {
            if let analyzer = hume {
                let segment = humeBuffer
                let capturedBus = bus
                Task { [weak self] in
                    guard let self else { return }
                    if let state = await analyzer.analyze(pcmData: segment) {
                        await self.context.update(.voiceEmotion(state))
                        if let b = capturedBus {
                            let emotions = state.emotions.map {
                                EmotionPayload.Emotion(label: $0.label, score: $0.score)
                            }
                            let payload = EmotionPayload(emotions: emotions, source: "hume_voice")
                            let event = BantiEvent(
                                source: "audio_cortex",
                                topic: "sensor.audio",
                                surprise: 0.4,
                                payload: .emotionUpdate(payload)
                            )
                            await b.publish(event, topic: "sensor.audio")
                        }
                    }
                }
            }
            humeBuffer = Data()   // always reset, even when hume is nil
        }
    }

    // MARK: - Testable accessors

    var humeBufferCount: Int { humeBuffer.count }
    var hasDeepgram: Bool { deepgram != nil }
    var hasHume: Bool { hume != nil }
}
