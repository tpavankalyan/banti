import Foundation
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import AppKit
import os

// MARK: - CameraFrameReplayProvider
// Co-located with its implementer, matching the AudioFrameReplayProvider pattern.

protocol CameraFrameReplayProvider: Actor {
    func replayFrames(after lastSeq: UInt64) async -> [(seq: UInt64, data: Data)]
}

// MARK: - CameraFrameActor

actor CameraFrameActor: BantiModule, CameraFrameReplayProvider {
    nonisolated let id = ModuleID("camera-capture")
    nonisolated let capabilities: Set<Capability> = [.videoCapture]

    private let logger = Logger(subsystem: "com.banti.camera-capture", category: "Capture")
    private let eventHub: EventHubActor
    private let config: ConfigActor

    private var captureSession: AVCaptureSession?
    private var drainTask: Task<Void, Never>?
    private var sequenceNumber: UInt64 = 0
    private var publishedFrameCount = 0
    private let frameBuffer = CameraLatestFrameBuffer()
    private var _health: ModuleHealth = .healthy

    private var replayBuffer: [(seq: UInt64, data: Data)] = []
    private let maxReplayFrames = 30

    // Inner class: bridges AVFoundation delegate callback (non-isolated) to actor-safe buffer.
    private final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let buffer: CameraLatestFrameBuffer
        private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        init(buffer: CameraLatestFrameBuffer) {
            self.buffer = buffer
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let jpeg = sampleBuffer.toScaledJPEG(maxEdge: 1280, quality: 0.7, context: ciContext) else { return }
            buffer.store(jpeg)
        }
    }

    private var captureDelegate: CaptureDelegate?

    init(eventHub: EventHubActor, config: ConfigActor) {
        self.eventHub = eventHub
        self.config = config
    }

    func start() async throws {
        let intervalMs = Int((await config.value(for: EnvKey.cameraCaptureIntervalMs))
            .flatMap(Int.init) ?? 200)

        let session = AVCaptureSession()
        session.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
            _health = .failed(error: ConfigError(message: "No camera device available"))
            throw ConfigError(message: "No camera device available")
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw ConfigError(message: "Cannot add camera input to session")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true

        let captureQueue = DispatchQueue(label: "com.banti.camera-capture", qos: .userInitiated)
        let delegate = CaptureDelegate(buffer: frameBuffer)
        output.setSampleBufferDelegate(delegate, queue: captureQueue)
        self.captureDelegate = delegate

        guard session.canAddOutput(output) else {
            throw ConfigError(message: "Cannot add video output to session")
        }
        session.addOutput(output)

        session.startRunning()
        self.captureSession = session
        _health = .healthy
        logger.notice("Camera capture session started (interval=\(intervalMs)ms)")

        startDrainTask(intervalMs: intervalMs)
    }

    func stop() async {
        drainTask?.cancel()
        drainTask = nil
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
        logger.info("Camera capture session stopped")
    }

    func health() -> ModuleHealth { _health }

    func replayFrames(after lastSeq: UInt64) -> [(seq: UInt64, data: Data)] {
        replayBuffer.filter { $0.seq > lastSeq }
    }

    /// Testing only — do not call from production code.
    func injectFrameForTesting(jpeg: Data, seq: UInt64) {
        appendToReplayBuffer(seq: seq, data: jpeg)
    }

    private func appendToReplayBuffer(seq: UInt64, data: Data) {
        replayBuffer.append((seq: seq, data: data))
        if replayBuffer.count > maxReplayFrames {
            replayBuffer.removeFirst()
        }
    }

    private func startDrainTask(intervalMs: Int) {
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(intervalMs))
                guard !Task.isCancelled, let self else { return }
                await self.drainLatestFrame()
            }
        }
    }

    private func drainLatestFrame() async {
        guard let jpeg = frameBuffer.take() else { return }

        sequenceNumber += 1
        publishedFrameCount += 1

        let (width, height) = jpegDimensions(jpeg)

        let event = CameraFrameEvent(
            jpeg: jpeg,
            sequenceNumber: sequenceNumber,
            frameWidth: width,
            frameHeight: height
        )

        appendToReplayBuffer(seq: sequenceNumber, data: jpeg)

        await eventHub.publish(event)

        if publishedFrameCount == 1 || publishedFrameCount.isMultiple(of: 50) {
            logger.notice("Published \(self.publishedFrameCount) camera frames")
        }
    }

    private func jpegDimensions(_ data: Data) -> (Int, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return (0, 0) }
        return (w, h)
    }
}

// MARK: - CMSampleBuffer → Scaled JPEG

private extension CMSampleBuffer {
    func toScaledJPEG(maxEdge: CGFloat, quality: CGFloat, context: CIContext) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(self) else { return nil }

        let width = CGFloat(CVPixelBufferGetWidth(imageBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(imageBuffer))
        let scale = min(1.0, maxEdge / max(width, height))

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let scaled = scale < 1.0
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
