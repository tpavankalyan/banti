// Sources/BantiCore/AudioRouter.swift
import Foundation

public actor AudioRouter: AudioChunkDispatcher {
    private let context: PerceptionContext
    private let logger: Logger

    private var deepgram: DeepgramStreamer?
    private var hume: HumeVoiceAnalyzer?
    private var humeBuffer: Data = Data()

    /// 3 seconds at 16kHz × 1 channel × 2 bytes/sample = 96,000 bytes.
    static let humeFlushThreshold = 96_000

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
            deepgram = DeepgramStreamer(apiKey: key, context: context, logger: logger)
        } else {
            logger.log(source: "audio", message: "[warn] DEEPGRAM_API_KEY missing — speech transcription disabled")
        }
        if let key = humeKey {
            hume = HumeVoiceAnalyzer(apiKey: key, context: context, logger: logger)
        } else {
            logger.log(source: "audio", message: "[warn] HUME_API_KEY missing — vocal emotion disabled")
        }
    }

    // MARK: - Dispatch (AudioChunkDispatcher)

    public func dispatch(pcmChunk: Data) async {
        // Stream every chunk to Deepgram (direct await preserves chunk ordering)
        if let streamer = deepgram {
            await streamer.send(chunk: pcmChunk)
        }

        humeBuffer.append(pcmChunk)
        if humeBuffer.count >= AudioRouter.humeFlushThreshold {
            if let analyzer = hume {
                let segment = humeBuffer
                Task { [weak self] in
                    guard let self else { return }
                    if let state = await analyzer.analyze(pcmData: segment) {
                        await self.context.update(.voiceEmotion(state))
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
