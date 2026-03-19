// Sources/BantiCore/GPT4oGestureAnalyzer.swift
import Foundation
import Vision

public final class GPT4oGestureAnalyzer: CloudAnalyzer {
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
        let base64 = jpegData.base64EncodedString()
        let keypoints = GPT4oGestureAnalyzer.keypointJSON(from: events)

        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": 80,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
                    ["type": "text", "text": "Body keypoints (normalized 0-1 coordinates): \(keypoints)\n\nIn one sentence, describe the person's posture, gesture, or body language. Be specific (e.g. 'leaning forward, hands on keyboard' or 'arms crossed, head tilted')."]
                ]
            ]]
        ]
        guard let text = await callGPT4o(apiKey: apiKey, body: body, logger: logger, session: session) else {
            return nil
        }
        return .gesture(GestureState(description: text, updatedAt: Date()))
    }

    /// Serialize body/hand keypoints from perception events to a compact JSON string.
    public static func keypointJSON(from events: [PerceptionEvent]) -> String {
        var points: [String: [String: Double]] = [:]

        for event in events {
            if case .bodyPoseDetected(let obs) = event {
                let jointNames = VNHumanBodyPoseObservation.JointName.allJoints
                for joint in jointNames {
                    if let point = try? obs.recognizedPoint(joint), point.confidence > 0.3 {
                        points["body_\(joint.rawValue.rawValue)"] = ["x": Double(point.x), "y": Double(point.y)]
                    }
                }
            }
            if case .handPoseDetected(let obs) = event {
                let jointNames = VNHumanHandPoseObservation.JointName.allJoints
                for joint in jointNames {
                    if let point = try? obs.recognizedPoint(joint), point.confidence > 0.3 {
                        points["hand_\(joint.rawValue.rawValue)"] = ["x": Double(point.x), "y": Double(point.y)]
                    }
                }
            }
        }

        guard !points.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: points),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// Extend joint name enums to provide all known joints
extension VNHumanBodyPoseObservation.JointName {
    static var allJoints: [VNHumanBodyPoseObservation.JointName] {
        [.nose, .leftEye, .rightEye, .leftEar, .rightEar,
         .leftShoulder, .rightShoulder, .neck,
         .leftElbow, .rightElbow, .leftWrist, .rightWrist,
         .leftHip, .rightHip, .root,
         .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
    }
}

extension VNHumanHandPoseObservation.JointName {
    static var allJoints: [VNHumanHandPoseObservation.JointName] {
        [.wrist,
         .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
         .indexMCP, .indexPIP, .indexDIP, .indexTip,
         .middleMCP, .middlePIP, .middleDIP, .middleTip,
         .ringMCP, .ringPIP, .ringDIP, .ringTip,
         .littleMCP, .littlePIP, .littleDIP, .littleTip]
    }
}
