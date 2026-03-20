import Foundation
@preconcurrency import AVFoundation
import os

protocol AudioFrameReplayProvider: Actor {
    func replayFrames(after lastSeq: UInt64) async -> [(seq: UInt64, data: Data)]
}

actor MicrophoneCaptureActor: PerceptionModule, AudioFrameReplayProvider {
    nonisolated let id = ModuleID("mic-capture")
    nonisolated let capabilities: Set<Capability> = [.audioCapture]

    private let logger = Logger(subsystem: "com.banti.mic-capture", category: "Capture")
    private let eventHub: EventHubActor
    private let sampleRate: Double = 16000
    private let bufferDuration: TimeInterval = 0.1

    private var audioEngine: AVAudioEngine?
    private var drainTask: Task<Void, Never>?
    private var sequenceNumber: UInt64 = 0
    private let bridgeBuffer = AudioRingBuffer()
    private var _health: ModuleHealth = .healthy

    private var replayBuffer: [(seq: UInt64, data: Data)] = []
    private let maxReplayFrames = 100

    init(eventHub: EventHubActor) {
        self.eventHub = eventHub
    }

    func start() async throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            _health = .failed(error: ConfigError(message: "No audio input available"))
            throw ConfigError(message: "No audio input available")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw ConfigError(message: "Cannot create target audio format")
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw ConfigError(message: "Cannot create audio converter")
        }

        let bufferSize = AVAudioFrameCount(sampleRate * bufferDuration)
        let bridge = self.bridgeBuffer

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) {
            buffer, _ in
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: bufferSize
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else { return }

            let frameLength = Int(convertedBuffer.frameLength)
            guard frameLength > 0,
                  let channelData = convertedBuffer.int16ChannelData else { return }
            let data = Data(bytes: channelData[0], count: frameLength * 2)

            bridge.append(data)
        }

        try engine.start()
        self.audioEngine = engine
        _health = .healthy
        logger.info("Audio engine started at \(self.sampleRate)Hz")

        startDrainTask()
    }

    func stop() async {
        drainTask?.cancel()
        drainTask = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        logger.info("Audio engine stopped")
    }

    func health() -> ModuleHealth { _health }

    func replayFrames(after lastSeq: UInt64) -> [(seq: UInt64, data: Data)] {
        replayBuffer.filter { $0.seq > lastSeq }
    }

    private func startDrainTask() {
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                await self.drainPendingFrames()
            }
        }
    }

    private func drainPendingFrames() async {
        let frames = bridgeBuffer.drain()
        for frame in frames {
            sequenceNumber += 1
            let event = AudioFrameEvent(
                audioData: frame,
                sequenceNumber: sequenceNumber,
                sampleRate: Int(sampleRate)
            )
            replayBuffer.append((seq: sequenceNumber, data: frame))
            if replayBuffer.count > maxReplayFrames {
                replayBuffer.removeFirst()
            }
            await eventHub.publish(event)
        }
    }
}
