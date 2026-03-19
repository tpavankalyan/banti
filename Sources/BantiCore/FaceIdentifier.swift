// Sources/BantiCore/FaceIdentifier.swift
import Foundation
import Vision

public actor FaceIdentifier {
    private let context: PerceptionContext
    private let sidecar: MemorySidecar
    private let logger: Logger
    public nonisolated let sessionID: String

    public init(context: PerceptionContext, sidecar: MemorySidecar, logger: Logger, sessionID: String) {
        self.context = context
        self.sidecar = sidecar
        self.logger = logger
        self.sessionID = sessionID
    }

    public func dispatch(jpegData: Data, faceObservation: VNFaceObservation) async {
        guard await sidecar.isRunning else { return }

        let jpeg64 = jpegData.base64EncodedString()
        let body: [String: String] = [
            "jpeg_b64": jpeg64,
            "session_id": sessionID
        ]

        guard let responseData = await sidecar.post(path: "/identity/face", body: body) else { return }

        do {
            let decoded = try JSONDecoder().decode(IdentityAPIResponse.self, from: responseData)
            let state = PersonState(
                id: decoded.person_id,
                name: decoded.name,
                confidence: decoded.confidence,
                updatedAt: Date()
            )
            await context.update(.person(state))
            if let name = decoded.name {
                logger.log(source: "memory", message: "face recognized: \(name) (\(decoded.person_id))")
            } else {
                logger.log(source: "memory", message: "face unknown: \(decoded.person_id)")
            }
        } catch {
            logger.log(source: "memory", message: "[warn] face identity parse error: \(error.localizedDescription)")
        }
    }

    private struct IdentityAPIResponse: Decodable {
        let matched: Bool
        let person_id: String
        let name: String?
        let confidence: Float
    }
}
