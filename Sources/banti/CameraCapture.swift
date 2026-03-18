// Sources/banti/CameraCapture.swift
import AVFoundation
import CoreImage
import Foundation

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let logger: Logger
    private var deduplicator: Deduplicator  // var: struct state must persist across callbacks
    private let vision: LocalVision
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "banti.camera", qos: .userInitiated)
    private var lastFrameTime: CMTime = .zero

    init(logger: Logger, deduplicator: Deduplicator, vision: LocalVision) {
        self.logger = logger
        self.deduplicator = deduplicator
        self.vision = vision
    }

    // Request permission and start capture if granted
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if granted {
                self.configureAndStart()
            } else {
                self.logger.log(source: "system", message: "[error] Camera permission denied — camera capture disabled")
            }
        }
    }

    private func configureAndStart() {
        let session = AVCaptureSession()
        session.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            logger.log(source: "system", message: "[error] No front camera available")
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        output.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        self.session = session
        session.startRunning()
    }

    // AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // Throttle to 1fps
        guard CMTimeSubtract(presentationTime, lastFrameTime).seconds >= 1.0 else { return }
        lastFrameTime = presentationTime

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // deduplicator is a struct — mutate self.deduplicator directly so state persists
        guard deduplicator.isNew(pixelBuffer: pixelBuffer, source: "camera") else { return }

        // Encode to JPEG synchronously before buffer is released
        guard let jpegData = jpegData(from: pixelBuffer) else { return }
        vision.analyze(jpegData: jpegData, source: "camera")
    }

    private func jpegData(from buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        return context.jpegRepresentation(of: ciImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
    }
}
