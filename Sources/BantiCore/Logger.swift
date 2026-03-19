// Sources/BantiCore/Logger.swift
import Foundation

public final class Logger {
    private let queue = DispatchQueue(label: "banti.logger")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let logFileURL: URL?
    // Override used in tests to capture output without touching files or terminal
    private let outputOverride: ((String) -> Void)?

    /// Production init — writes colored output to terminal + plain text to ~/Library/Logs/banti/
    public init() {
        outputOverride = nil
        let logsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/banti", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let dateStr = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        logFileURL = logsDir.appendingPathComponent("banti-\(dateStr).log")
    }

    /// Test init — captures output via closure, no file I/O, no colors
    public init(_ output: @escaping (String) -> Void) {
        outputOverride = output
        logFileURL = nil
    }

    public func log(source: String, message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = self.formatter.string(from: Date())
            let plain = "[\(timestamp)] [source: \(source)] \(message)"

            if let override = self.outputOverride {
                override(plain)
                return
            }

            // Colored terminal output
            print(self.colorize(source: source, line: plain))

            // Plain text append to log file
            guard let url = self.logFileURL else { return }
            let line = plain + "\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path) {
                    if let handle = try? FileHandle(forWritingTo: url) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }

    // MARK: - ANSI colors

    private func colorize(source: String, line: String) -> String {
        let color: String
        switch source {
        case "system":     color = ANSI.dim
        case "ax":         color = ANSI.blue
        case "perception": color = ANSI.green
        case "hume":       color = ANSI.magenta
        case "gpt4o":      color = ANSI.yellow
        case "camera":     color = ANSI.cyan
        case "screen":     color = ANSI.cyan
        case "deepgram":    color = ANSI.cyan
        case "hume-voice":  color = ANSI.magenta
        case "sound":       color = ANSI.yellow
        case "audio":       color = ANSI.white
        default:           color = ANSI.white
        }

        return line.replacingOccurrences(
            of: "[source: \(source)]",
            with: "\(color)[source: \(source)]\(ANSI.reset)"
        )
    }
}

private enum ANSI {
    static let reset   = "\u{001B}[0m"
    static let dim     = "\u{001B}[2m"
    static let white   = "\u{001B}[37m"
    static let cyan    = "\u{001B}[36m"
    static let green   = "\u{001B}[32m"
    static let yellow  = "\u{001B}[33m"
    static let blue    = "\u{001B}[34m"
    static let magenta = "\u{001B}[35m"
}
