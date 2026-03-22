// Banti/Banti/Modules/Perception/Camera/FrameDifferencer.swift
import Foundation
import Vision
import AppKit

// MARK: - Protocol

/// Computes perceptual distance between successive frames using VNFeaturePrint.
/// First call always returns nil (no prior reference). Subsequent calls return
/// [0, ∞) distance and update the stored reference.
protocol FrameDifferencer: Actor {
    func distance(from jpeg: Data) throws -> Float?
}

// MARK: - Production Implementation

actor VNFrameDifferencer: FrameDifferencer {
    private var reference: VNFeaturePrintObservation?

    func distance(from jpeg: Data) throws -> Float? {
        let current = try computePrint(jpeg: jpeg)
        defer { reference = current }
        guard let ref = reference else { return nil }
        var dist: Float = 0
        try ref.computeDistance(&dist, to: current)
        return dist
    }

    private func computePrint(jpeg: Data) throws -> VNFeaturePrintObservation {
        guard let image = NSImage(data: jpeg),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw FrameDifferencerError("Cannot decode JPEG for feature print") }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first as? VNFeaturePrintObservation else {
            throw FrameDifferencerError("No feature print result returned")
        }
        return result
    }
}

// MARK: - Error

struct FrameDifferencerError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
