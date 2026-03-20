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

/// Production implementation — calls Cerebras API via URLSession.
public func makeLiveCerebrasCompletion(apiKey: String) -> CerebrasCompletion {
    return { model, systemPrompt, userContent, maxTokens in
        let url = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }
}
