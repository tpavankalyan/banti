// Sources/BantiCore/CerebrasClient.swift
import Foundation

/// Injectable LLM completion function. All Cerebras nodes accept this type.
/// model: Cerebras model string (e.g. "llama3.1-8b")
/// systemPrompt: system message
/// userContent: user message
/// maxTokens: upper bound
/// Returns: completion text
public typealias CerebrasCompletion = @Sendable (
    _ model: String,
    _ systemPrompt: String,
    _ userContent: String,
    _ maxTokens: Int
) async throws -> String

public struct CerebrasHTTPError: Error, LocalizedError, CustomStringConvertible {
    public let statusCode: Int
    public let responseBody: String

    public init(statusCode: Int, responseBody: String) {
        self.statusCode = statusCode
        self.responseBody = responseBody
    }

    private var bodyPreview: String {
        let trimmed = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return HTTPURLResponse.localizedString(forStatusCode: statusCode) }
        if trimmed.count > 500 {
            return String(trimmed.prefix(500)) + "..."
        }
        return trimmed
    }

    public var errorDescription: String? { description }
    public var description: String { "Cerebras HTTP \(statusCode): \(bodyPreview)" }
}

/// Production implementation — calls Cerebras API via URLSession.
public func makeLiveCerebrasCompletion(
    apiKey: String,
    sessionFactory: @escaping () -> URLSession = {
        // Use isolated ephemeral sessions so transient broken connections don't poison long-lived state.
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }
) -> CerebrasCompletion {
    let makeSession = sessionFactory
    let retryableTransportCodes: Set<URLError.Code> = [
        .cannotParseResponse,
        .networkConnectionLost,
        .timedOut,
        .cannotConnectToHost
    ]
    return { model, systemPrompt, userContent, maxTokens in
        let url = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        var lastError: Error?

        for attempt in 0..<3 {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userContent]
                ],
                "max_tokens": maxTokens
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            do {
                let (data, response) = try await makeSession().data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.cannotParseResponse)
                }
                guard (200...299).contains(http.statusCode) else {
                    let body = String(decoding: data, as: UTF8.self)
                    throw CerebrasHTTPError(statusCode: http.statusCode, responseBody: body)
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw URLError(.cannotParseResponse)
                }
                return content
            } catch let urlError as URLError {
                lastError = urlError
                if attempt < 2 && retryableTransportCodes.contains(urlError.code) {
                    let backoffNs = UInt64((attempt + 1) * 200_000_000)
                    try? await Task.sleep(nanoseconds: backoffNs)
                    continue
                }
                throw urlError
            } catch {
                throw error
            }
        }

        throw lastError ?? URLError(.unknown)
    }
}
