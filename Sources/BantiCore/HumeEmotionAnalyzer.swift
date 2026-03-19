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
        // Hume streaming endpoint requires WebSocket (wss://), not HTTP POST
        guard let url = URL(string: "wss://api.hume.ai/v0/stream/models?api_key=\(apiKey)") else { return nil }

        let body: [String: Any] = [
            "models": ["face": [:]],
            "data":   imageData.base64EncodedString()
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let bodyString = String(data: bodyData, encoding: .utf8) else { return nil }

        let task = session.webSocketTask(with: url)
        task.resume()

        do {
            try await task.send(.string(bodyString))
            let message = try await withTimeout(seconds: 10) {
                try await task.receive()
            }
            task.cancel(with: .normalClosure, reason: nil)

            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8) else { return nil }
                return parseResponse(data: data)
            case .data(let data):
                return parseResponse(data: data)
            @unknown default:
                return nil
            }
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            logger.log(source: "hume", message: "[warn] \(error.localizedDescription)")
            return nil
        }
    }

    private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func parseResponse(data: Data) -> PerceptionObservation? {
        // WebSocket response: {"face": {"predictions": [{"emotions": [...]}]}}
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
