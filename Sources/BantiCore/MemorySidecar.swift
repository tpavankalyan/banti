// Sources/BantiCore/MemorySidecar.swift
import Foundation

public actor MemorySidecar {
    public static let defaultPort = 7700

    public nonisolated let baseURL: URL
    private let logger: Logger
    private var process: Process?
    public var isRunning: Bool = false

    public init(logger: Logger, port: Int = defaultPort) {
        self.logger = logger
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    public func start() async {
        guard !isRunning else { return }

        let sidecarDir = resolveSidecarDir()
        let pythonPath = sidecarDir.appendingPathComponent(".venv/bin/python3").path
        let mainPath = sidecarDir.appendingPathComponent("main.py").path

        guard FileManager.default.fileExists(atPath: mainPath) else {
            logger.log(source: "memory", message: "[warn] sidecar not found at \(mainPath) — memory disabled")
            return
        }

        let python = FileManager.default.fileExists(atPath: pythonPath) ? pythonPath : "/usr/bin/python3"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [mainPath]
        proc.currentDirectoryURL = sidecarDir
        proc.environment = ProcessInfo.processInfo.environment

        do {
            try proc.run()
            process = proc
            logger.log(source: "memory", message: "sidecar launched (pid \(proc.processIdentifier))")
        } catch {
            logger.log(source: "memory", message: "[warn] sidecar launch failed: \(error.localizedDescription)")
            return
        }

        await waitForHealth()
    }

    public func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    public func post<T: Encodable>(path: String, body: T) async -> Data? {
        guard isRunning else { return nil }
        guard let url = URL(string: path, relativeTo: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0
        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        } catch {
            return nil
        }
    }

    private func resolveSidecarDir() -> URL {
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("memory_sidecar")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        if let execURL = Bundle.main.executableURL {
            let projectRoot = execURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return projectRoot.appendingPathComponent("memory_sidecar")
        }
        return URL(fileURLWithPath: "memory_sidecar")
    }

    private func waitForHealth(attempts: Int = 20) async {
        let healthURL = baseURL.appendingPathComponent("health")
        for _ in 0..<attempts {
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                let (_, response) = try await URLSession.shared.data(from: healthURL)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    isRunning = true
                    logger.log(source: "memory", message: "sidecar ready at \(baseURL)")
                    return
                }
            } catch { }
        }
        logger.log(source: "memory", message: "[warn] sidecar did not respond in 10s — memory disabled")
    }
}
