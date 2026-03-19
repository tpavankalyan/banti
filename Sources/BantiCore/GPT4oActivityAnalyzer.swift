// Sources/BantiCore/GPT4oActivityAnalyzer.swift
import Foundation

public final class GPT4oActivityAnalyzer: CloudAnalyzer {
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
        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": 100,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
                    ["type": "text", "text": "In 1-2 sentences, describe what this person is doing right now. Focus on their activity and intent, not appearance."]
                ]
            ]]
        ]
        guard let text = await callGPT4o(apiKey: apiKey, body: body, logger: logger, session: session) else { return nil }
        return .activity(ActivityState(description: text, updatedAt: Date()))
    }
}

// Shared GPT-4o call helper used by activity, gesture, and screen analyzers.
// apiKey must be passed explicitly — do not read from environment here.
func callGPT4o(apiKey: String, body: [String: Any], logger: Logger, session: URLSession) async -> String? {
    guard let url = URL(string: "https://api.openai.com/v1/chat/completions"),
          let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.httpBody = bodyData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    do {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            logger.log(source: "gpt4o", message: "[warn] HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            return nil
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        logger.log(source: "gpt4o", message: "[warn] \(error.localizedDescription)")
        return nil
    }
}
