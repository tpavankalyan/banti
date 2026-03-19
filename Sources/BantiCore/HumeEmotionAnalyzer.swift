// Sources/BantiCore/HumeEmotionAnalyzer.swift
import Foundation
import Vision
import CoreGraphics
import ImageIO

public final class HumeEmotionAnalyzer: CloudAnalyzer {
    private let apiKey: String
    private let logger: Logger
    private let session: URLSession

    public init(apiKey: String, logger: Logger, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.logger = logger
        self.session = session
    }

    public func analyze(jpegData: Data?, events: [PerceptionEvent]) async -> PerceptionObservation? {
        guard let jpegData else { return nil }

        // Extract face bounding box from events
        let faceObservation = events.compactMap { event -> VNFaceObservation? in
            if case .faceDetected(let obs) = event { return obs }
            return nil
        }.first

        // Crop to face if detected; otherwise send full image
        let imageData: Data
        if let obs = faceObservation {
            imageData = crop(jpegData: jpegData, visionBox: obs.boundingBox) ?? jpegData
        } else {
            imageData = jpegData
        }

        return await callHumeAPI(imageData: imageData)
    }

    /// Crop JPEG to face region. Vision bounding box is normalized, bottom-left origin.
    func crop(jpegData: Data, visionBox: CGRect) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // Flip Y axis: Vision uses bottom-left origin; CGImage uses top-left
        let flipped = HumeEmotionAnalyzer.flipBoundingBox(visionBox)

        // Scale normalized coords to pixel coords; clamp to image bounds
        var pixelBox = CGRect(
            x: flipped.origin.x * imageWidth,
            y: flipped.origin.y * imageHeight,
            width:  flipped.width  * imageWidth,
            height: flipped.height * imageHeight
        )
        pixelBox = pixelBox.intersection(CGRect(origin: .zero, size: CGSize(width: imageWidth, height: imageHeight)))
        guard !pixelBox.isNull, pixelBox.width > 0, pixelBox.height > 0 else { return nil }

        guard let cropped = cgImage.cropping(to: pixelBox) else { return nil }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cropped, [kCGImageDestinationLossyCompressionQuality as String: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    /// Flip Vision bounding box from bottom-left to top-left origin (normalized coordinates).
    public static func flipBoundingBox(_ box: CGRect) -> CGRect {
        CGRect(
            x: box.origin.x,
            y: 1.0 - box.origin.y - box.height,
            width:  box.width,
            height: box.height
        )
    }

    private func callHumeAPI(imageData: Data) async -> PerceptionObservation? {
        guard let url = URL(string: "https://api.hume.ai/v0/stream/models") else { return nil }

        let body: [String: Any] = [
            "models": ["face": [:]],
            "data":   imageData.base64EncodedString()
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Hume-Api-Key")

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                logger.log(source: "hume", message: "[warn] HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            return parseResponse(data: data)
        } catch {
            logger.log(source: "hume", message: "[warn] \(error.localizedDescription)")
            return nil
        }
    }

    private func parseResponse(data: Data) -> PerceptionObservation? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let face = json["face"] as? [String: Any],
              let predictions = face["predictions"] as? [[String: Any]],
              let first = predictions.first,
              let emotions = first["emotions"] as? [[String: Any]] else { return nil }

        let top5 = emotions
            .compactMap { e -> (label: String, score: Float)? in
                guard let name = e["name"] as? String,
                      let score = e["score"] as? Double else { return nil }
                return (label: name, score: Float(score))
            }
            .sorted { $0.score > $1.score }
            .prefix(5)

        let state = EmotionState(emotions: Array(top5), updatedAt: Date())
        return .emotion(state)
    }
}
