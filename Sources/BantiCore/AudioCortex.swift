// Sources/BantiCore/AudioCortex.swift
import Foundation

public actor AudioCortex: CorticalNode {
    public let id = "audio_cortex"
    public let subscribedTopics = ["motor.voice"]

    private let deepgram: AnyObject?  // DeepgramStreamer? — nil in tests
    private let hume: AnyObject?      // HumeVoiceAnalyzer? — nil in tests
    private var _bus: EventBus?

    // Efference copy state
    private var isSpeaking: Bool = false
    private var tailWindowEndNs: UInt64 = 0
    private var tailWindowMsOverride: Int? = nil

    public init(deepgram: AnyObject?, hume: AnyObject?, bus: EventBus) {
        self.deepgram = deepgram
        self.hume = hume
        self._bus = bus
    }

    public func start(bus: EventBus) async {
        self._bus = bus
        await bus.subscribe(topic: "motor.voice") { [weak self] event in
            await self?.handle(event)
        }
    }

    public func handle(_ event: BantiEvent) async {
        guard case .voiceSpeaking(let v) = event.payload else { return }
        if v.speaking {
            isSpeaking = true
        } else {
            isSpeaking = false
            let ms = tailWindowMsOverride ?? v.tailWindowMs
            tailWindowEndNs = BantiClock.nowNs() + UInt64(ms) * 1_000_000
        }
    }

    private func isSuppressed() -> Bool {
        isSpeaking || BantiClock.nowNs() < tailWindowEndNs
    }

    /// Internal — for tests only. Simulates a Deepgram transcript arriving.
    func injectTranscriptForTest(_ text: String) async {
        guard !isSuppressed(), let bus = _bus else { return }
        let event = BantiEvent(
            source: id,
            topic: "sensor.audio",
            surprise: 1.0,
            payload: .speechDetected(SpeechPayload(transcript: text, speakerID: nil))
        )
        await bus.publish(event, topic: "sensor.audio")
    }

    /// Internal — for tests only. Overrides the tail window duration.
    func setTailWindowMsForTest(_ ms: Int) {
        tailWindowMsOverride = ms
    }
}
