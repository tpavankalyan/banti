// Sources/BantiCore/SoundClassifier.swift
import Foundation
import AVFoundation
import SoundAnalysis

public final class SoundClassifier: NSObject {
    private let context: PerceptionContext
    private let logger: Logger
    private let analysisQueue = DispatchQueue(label: "banti.soundclassifier", qos: .userInitiated)
    private var analyzer: SNAudioStreamAnalyzer?
    private var lastEmittedAt: Date?
    private static let throttleSeconds: Double = 1.0
    private static let confidenceThreshold: Float = 0.7

    /// Frame position counter — incremented synchronously for testability.
    public private(set) var currentFramePosition: AVAudioFramePosition = 0

    public init(context: PerceptionContext, logger: Logger) {
        self.context = context
        self.logger = logger
        super.init()
    }

    /// Call once with the hardware audio format before first analyze() call.
    public func setup(inputFormat: AVAudioFormat) {
        let streamAnalyzer = SNAudioStreamAnalyzer(format: inputFormat)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try streamAnalyzer.add(request, withObserver: self)
            analyzer = streamAnalyzer
        } catch {
            logger.log(source: "sound", message: "[warn] SoundAnalysis setup failed: \(error.localizedDescription)")
        }
    }

    /// Accepts native-rate AVAudioPCMBuffer from MicrophoneCapture's tap.
    /// Frame position incremented synchronously; analysis dispatched to serial queue.
    public func analyze(buffer: AVAudioPCMBuffer) {
        let pos = currentFramePosition
        currentFramePosition += AVAudioFramePosition(buffer.frameLength)
        analysisQueue.async { [weak self] in
            self?.analyzer?.analyze(buffer, atAudioFramePosition: pos)
        }
    }
}

// MARK: - SNResultsObserving

extension SoundClassifier: SNResultsObserving {
    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let top = result.classifications.first,
              Float(top.confidence) > SoundClassifier.confidenceThreshold else { return }

        let now = Date()
        if let last = lastEmittedAt, now.timeIntervalSince(last) < SoundClassifier.throttleSeconds { return }
        lastEmittedAt = now

        let state = SoundState(label: top.identifier, confidence: Float(top.confidence), updatedAt: now)
        logger.log(source: "sound", message: "\(top.identifier) (\(String(format: "%.2f", top.confidence)))")
        Task { await self.context.update(.sound(state)) }
    }

    public func request(_ request: SNRequest, didFailWithError error: Error) {
        logger.log(source: "sound", message: "[warn] analysis error: \(error.localizedDescription)")
    }
}
