// Sources/BantiCore/MicrophoneCapture.swift
import Foundation
import AVFoundation

public final class MicrophoneCapture {
    private let engine: AVAudioEngine
    private let dispatcher: any AudioChunkDispatcher
    private let soundClassifier: SoundClassifier
    private let logger: Logger
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    public init(engine: AVAudioEngine,
                dispatcher: any AudioChunkDispatcher,
                soundClassifier: SoundClassifier,
                logger: Logger) {
        self.engine = engine
        self.dispatcher = dispatcher
        self.soundClassifier = soundClassifier
        self.logger = logger
    }

    public func start() {
        requestPermissionAndStart()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        // Do not call engine.stop() — the engine is shared; its lifecycle is owned by main.swift.
    }

    // MARK: - Private

    private func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted { DispatchQueue.main.async { self?.startCapture() } }
                else { self?.permissionDenied() }
            }
        case .denied, .restricted:
            permissionDenied()
        @unknown default:
            break
        }
    }

    private func permissionDenied() {
        logger.log(source: "audio", message: "[error] Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone.")
        exit(1)
    }

    private func startCapture() {
        let inputNode = engine.inputNode

        // Enable macOS hardware AEC. Requires playerNode to already be attached to the
        // same engine (done in CartesiaSpeaker.init via MemoryEngine.init before this is called).
        // macOS uses the engine's output as the echo reference signal — analogous to the
        // brain's corollary discharge suppressing predicted self-generated sound.
        // setVoiceProcessingEnabled(true) was attempted here to enable macOS hardware AEC,
        // but it silences the microphone on this device (input receives near-zero signal).
        // The shared AVAudioEngine is still in place as the correct foundation — if a
        // per-device check or alternative AEC approach is found, enable it here.

        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Set up AVAudioConverter: hardware format → 16kHz mono Int16
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            logger.log(source: "audio", message: "[error] Failed to create AVAudioConverter from \(inputFormat) to 16kHz Int16")
            return
        }
        converter = conv

        // Set up SoundClassifier with the native hardware format (must happen before analyze calls)
        soundClassifier.setup(inputFormat: inputFormat)

        // Tap size: ~20ms at hardware rate
        let tapBufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.02)

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }

        do {
            try engine.start()
            logger.log(source: "audio", message: "microphone capture started (\(inputFormat.sampleRate)Hz → 16kHz)")
        } catch {
            logger.log(source: "audio", message: "[error] AVAudioEngine start failed: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
        }
    }

    private func processTap(buffer: AVAudioPCMBuffer) {
        // Branch 1: SoundClassifier gets the native-rate buffer (before downsampling)
        soundClassifier.analyze(buffer: buffer)

        // Branch 2: Convert to 16kHz Int16 and dispatch to AudioRouter
        guard let conv = converter else { return }

        let inputFrameCount = buffer.frameLength
        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(inputFrameCount) * targetFormat.sampleRate / buffer.format.sampleRate)
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return }

        var error: NSError?
        var inputConsumed = false
        let status = conv.convert(to: outputBuffer, error: &error) { packetCount, statusPtr in
            if inputConsumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            statusPtr.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, outputBuffer.frameLength > 0 else { return }

        // Package Int16 frames as Data and dispatch
        let byteCount = Int(outputBuffer.frameLength) * 2  // 2 bytes per Int16 frame
        guard let int16Ptr = outputBuffer.int16ChannelData?[0] else { return }
        let chunk = Data(bytes: int16Ptr, count: byteCount)

        // AVAudioEngine tap is synchronous; use Task to call the async dispatcher
        Task { await dispatcher.dispatch(pcmChunk: chunk) }
    }
}
