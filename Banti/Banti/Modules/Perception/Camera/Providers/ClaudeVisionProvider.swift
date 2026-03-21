import Foundation
import os

struct ClaudeVisionProvider: VisionProvider {
    private let logger = Logger(subsystem: "com.banti.vision", category: "Claude")

    private let apiKey: String
    let model: String  // internal let — exposed for testability

    static let defaultModel = "claude-haiku-4-5"

    init(apiKey: String, model: String = ClaudeVisionProvider.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    func describe(jpeg: Data, prompt: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let base64Image = jpeg.base64EncodedString()
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ],
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw VisionError("Invalid response from Claude Vision")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw VisionError("Claude Vision \(http.statusCode): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String
        else {
            throw VisionError("Unexpected Claude Vision response format")
        }

        logger.notice("Scene described: \(text.prefix(80), privacy: .public)")
        return text
    }
}
