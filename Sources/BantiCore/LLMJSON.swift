import Foundation

enum LLMJSON {
    static func decode<T: Decodable>(_ type: T.Type, from rawText: String) -> T? {
        let decoder = JSONDecoder()
        if let direct = rawText.data(using: .utf8),
           let parsed = try? decoder.decode(type, from: direct) {
            return parsed
        }

        for candidate in candidateJSONStrings(from: rawText) {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let parsed = try? decoder.decode(type, from: data) {
                return parsed
            }
        }
        return nil
    }

    private static func candidateJSONStrings(from rawText: String) -> [String] {
        var candidates: [String] = []
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        candidates.append(trimmed)

        let nsText = trimmed as NSString
        let codeBlockPattern = "```(?:json)?\\s*([\\s\\S]*?)\\s*```"
        if let regex = try? NSRegularExpression(pattern: codeBlockPattern, options: [.caseInsensitive]) {
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsText.length))
            for match in matches where match.numberOfRanges > 1 {
                let block = nsText.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !block.isEmpty {
                    candidates.append(block)
                }
            }
        }

        if let objectCandidate = firstBalancedJSON(in: trimmed, open: "{", close: "}") {
            candidates.append(objectCandidate)
        }
        if let arrayCandidate = firstBalancedJSON(in: trimmed, open: "[", close: "]") {
            candidates.append(arrayCandidate)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func firstBalancedJSON(in text: String, open: Character, close: Character) -> String? {
        guard let start = text.firstIndex(of: open) else { return nil }
        var depth = 0
        var inString = false
        var escaping = false
        var index = start

        while index < text.endIndex {
            let ch = text[index]

            if escaping {
                escaping = false
            } else if ch == "\\" && inString {
                escaping = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == open {
                    depth += 1
                } else if ch == close {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }

        return nil
    }
}
