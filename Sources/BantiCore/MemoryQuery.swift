// Sources/BantiCore/MemoryQuery.swift
import Foundation

public struct MemoryQuery {
    private let sidecar: MemorySidecar
    private let logger: Logger

    public init(sidecar: MemorySidecar, logger: Logger) {
        self.sidecar = sidecar
        self.logger = logger
    }

    public func query(_ text: String, context: PerceptionContext? = nil) async -> MemoryResponse {
        guard await sidecar.isRunning else {
            return MemoryResponse(answer: "Memory unavailable — sidecar not running", sources: [])
        }

        struct QueryBody: Encodable {
            let q: String
            let context_json: String?
        }

        let contextJSON = await context?.snapshotJSON()
        let body = QueryBody(q: text, context_json: contextJSON)

        guard let data = await sidecar.post(path: "/memory/query", body: body) else {
            return MemoryResponse(answer: "", sources: [])
        }

        struct QueryAPIResponse: Decodable {
            let answer: String
            let sources: [String]
        }

        guard let response = try? JSONDecoder().decode(QueryAPIResponse.self, from: data) else {
            return MemoryResponse(answer: "", sources: [])
        }

        return MemoryResponse(answer: response.answer, sources: response.sources)
    }
}
