// Sources/BantiCore/GPT4oScreenAnalyzer.swift
import Foundation

public final class GPT4oScreenAnalyzer: CloudAnalyzer {
    private let apiKey: String
    private let logger: Logger
    private let session: URLSession

    public init(apiKey: String, logger: Logger, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.logger = logger
        self.session = session
    }

    public func analyze(jpegData: Data?, events: [PerceptionEvent]) async -> PerceptionObservation? {
        // Screen analyzer is text-only — no image needed
        let ocrLines = events.compactMap { event -> [String]? in
            if case .textRecognized(let lines) = event { return lines }
            return nil
        }.flatMap { $0 }

        guard !ocrLines.isEmpty else { return nil }

        let ocrText = ocrLines.joined(separator: "\n")
        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": 80,
            "messages": [[
                "role": "user",
                "content": "The following text was read from a computer screen via OCR:\n\n\(ocrText)\n\nIn one sentence, describe what the user is reading or working on."
            ]]
        ]

        guard let description = await callGPT4o(apiKey: apiKey, body: body, logger: logger, session: session) else {
            return nil
        }
        return .screen(ScreenState(ocrLines: ocrLines, interpretation: description, updatedAt: Date()))
    }
}
