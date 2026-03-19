// Sources/banti/ScreenCapture.swift
import ScreenCaptureKit
import Foundation
import CoreImage
import AppKit

public final class ScreenCapture: NSObject, SCStreamOutput {
    private let logger: Logger
    private var deduplicator: Deduplicator  // var: struct state must persist across callbacks
    private let frameProcessor: FrameProcessor
    private var stream: SCStream?
    private var lastFrameTime: CMTime = .zero

    public init(logger: Logger, deduplicator: Deduplicator, frameProcessor: FrameProcessor) {
        self.logger = logger
        self.deduplicator = deduplicator
        self.frameProcessor = frameProcessor
    }

    public func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = primaryDisplay(from: content) else {
                logger.log(source: "system", message: "[error] No primary display found")
                return
            }

            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1fps
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.capturesShadowsOnly = false

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            logger.log(source: "system", message: "[error] Screen recording permission denied — screen capture disabled")
        }
    }

    // SCStreamOutput
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeSubtract(presentationTime, lastFrameTime).seconds >= 1.0 else { return }
        lastFrameTime = presentationTime

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard deduplicator.isNew(pixelBuffer: pixelBuffer, source: "screen") else { return }

        // Encode to JPEG synchronously before buffer is released
        guard let jpegData = jpegData(from: pixelBuffer) else { return }
        frameProcessor.process(jpegData: jpegData, source: "screen")
    }

    private func primaryDisplay(from content: SCShareableContent) -> SCDisplay? {
        guard let mainScreen = NSScreen.main else { return content.displays.first }
        let mainID = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first
    }

    private func jpegData(from buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        return context.jpegRepresentation(of: ciImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
    }
}
