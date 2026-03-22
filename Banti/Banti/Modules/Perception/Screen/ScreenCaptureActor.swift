import Foundation
import ScreenCaptureKit
import CoreImage
import AppKit
import os

// MARK: - ScreenCaptureActor

actor ScreenCaptureActor: BantiModule {
    nonisolated let id = ModuleID("screen-capture")
    nonisolated let capabilities: Set<Capability> = [.screenCapture]

    private let logger = Logger(subsystem: "com.banti.screen-capture", category: "Capture")
    private let eventHub: EventHubActor
    private let config: ConfigActor

    private var stream: SCStream?
    private var streamOutput: ScreenStreamOutput?
    private var drainTask: Task<Void, Never>?
    private var sequenceNumber: UInt64 = 0
    private var publishedFrameCount = 0
    private let frameBuffer = ScreenLatestFrameBuffer()
    private var _health: ModuleHealth = .healthy

    init(eventHub: EventHubActor, config: ConfigActor) {
        self.eventHub = eventHub
        self.config = config
    }

    func start() async throws {
        let intervalMs = Int((await config.value(for: EnvKey.screenCaptureIntervalMs))
            .flatMap(Int.init) ?? 1000)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            _health = .failed(error: error)
            throw error
        }

        guard let display = content.displays.first else {
            let err = ConfigError(message: "No display available for screen capture")
            _health = .failed(error: err)
            throw err
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = display.width
        streamConfig.height = display.height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 2) // 2fps max from SCStream
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.showsCursor = false

        let output = ScreenStreamOutput(buffer: frameBuffer)
        self.streamOutput = output

        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        try scStream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.banti.screen-capture", qos: .userInitiated)
        )
        try await scStream.startCapture()
        self.stream = scStream

        _health = .healthy
        logger.notice("Screen capture started (interval=\(intervalMs)ms, display=\(display.width)x\(display.height))")

        startDrainTask(intervalMs: intervalMs)
    }

    func stop() async {
        drainTask?.cancel()
        drainTask = nil
        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil
        streamOutput = nil
        logger.info("Screen capture stopped")
    }

    func health() async -> ModuleHealth { _health }

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
        let event = ScreenFrameEvent(
            jpeg: jpeg,
            sequenceNumber: sequenceNumber,
            displayWidth: width,
            displayHeight: height
        )
        await eventHub.publish(event)

        if publishedFrameCount == 1 || publishedFrameCount.isMultiple(of: 30) {
            logger.notice("Published \(self.publishedFrameCount) screen frames")
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

// MARK: - ScreenStreamOutput

private final class ScreenStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let buffer: ScreenLatestFrameBuffer
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(buffer: ScreenLatestFrameBuffer) {
        self.buffer = buffer
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let jpeg = scaledJPEG(from: sampleBuffer, maxEdge: 1920, quality: 0.6)
        else { return }
        buffer.store(jpeg)
    }

    private func scaledJPEG(from sampleBuffer: CMSampleBuffer, maxEdge: CGFloat, quality: CGFloat) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let width = CGFloat(CVPixelBufferGetWidth(imageBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(imageBuffer))
        let scale = min(1.0, maxEdge / max(width, height))

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let scaled = scale < 1.0
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage

        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
