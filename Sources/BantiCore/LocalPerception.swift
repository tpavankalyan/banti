// Sources/BantiCore/LocalPerception.swift
import Vision
import Foundation

public final class LocalPerception: FrameProcessor {
    private let dispatcher: PerceptionDispatcher   // protocol — no forward dependency on PerceptionRouter
    private let analysisQueue = DispatchQueue(label: "banti.vision", qos: .userInitiated)

    public init(dispatcher: PerceptionDispatcher) {
        self.dispatcher = dispatcher
    }

    // FrameProcessor conformance — called from capture layer
    public func process(jpegData: Data, source: String) {
        analysisQueue.async { [weak self] in
            self?.analyze(jpegData: jpegData, source: source)
        }
    }

    private func analyze(jpegData: Data, source: String) {
        let handler = VNImageRequestHandler(data: jpegData, options: [:])
        var events: [PerceptionEvent] = []

        if source == "camera" {
            events = analyzeCameraFrame(handler: handler)
        } else if source == "screen" {
            events = analyzeScreenFrame(handler: handler)
        }

        Task { [weak self] in
            await self?.dispatcher.dispatch(jpegData: jpegData, source: source, events: events)
        }
    }

    private func analyzeCameraFrame(handler: VNImageRequestHandler) -> [PerceptionEvent] {
        var events: [PerceptionEvent] = []

        // Face detection + landmarks
        let faceRequest = VNDetectFaceRectanglesRequest()
        let landmarkRequest = VNDetectFaceLandmarksRequest()
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()
        let sceneRequest = VNClassifyImageRequest()

        try? handler.perform([faceRequest, landmarkRequest, bodyRequest, handRequest, humanRequest, sceneRequest])

        // Prefer landmark observations (they include bounding boxes too)
        if let faces = landmarkRequest.results, let face = faces.first {
            events.append(.faceDetected(observation: face))
        } else if let humans = humanRequest.results, !humans.isEmpty {
            events.append(.humanPresent)
        }

        if let bodies = bodyRequest.results, let body = bodies.first {
            events.append(.bodyPoseDetected(observation: body))
        }

        if let hands = handRequest.results, let hand = hands.first {
            events.append(.handPoseDetected(observation: hand))
        }

        if let scene = sceneRequest.results, !scene.isEmpty {
            let labels = scene.prefix(5).map { (identifier: $0.identifier, confidence: $0.confidence) }
            events.append(.sceneClassified(labels: labels))
        }

        return events.isEmpty ? [.nothingDetected] : events
    }

    private func analyzeScreenFrame(handler: VNImageRequestHandler) -> [PerceptionEvent] {
        var events: [PerceptionEvent] = []

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        let sceneRequest = VNClassifyImageRequest()

        try? handler.perform([textRequest, sceneRequest])

        if let observations = textRequest.results {
            let lines = observations
                .filter { $0.topCandidates(1).first?.confidence ?? 0 >= 0.5 }
                .compactMap { $0.topCandidates(1).first?.string }
            if !lines.isEmpty {
                events.append(.textRecognized(lines: lines))
            }
        }

        if let scene = sceneRequest.results, !scene.isEmpty {
            let labels = scene.prefix(5).map { (identifier: $0.identifier, confidence: $0.confidence) }
            events.append(.sceneClassified(labels: labels))
        }

        return events.isEmpty ? [.nothingDetected] : events
    }
}
