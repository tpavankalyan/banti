// Sources/banti/LocalVision.swift
import Foundation

public final class LocalVision {
    private let session: URLSession
    private let logger: Logger
    private let semaphore = DispatchSemaphore(value: 2)
    private let inferenceQueue = DispatchQueue(label: "banti.inference", attributes: .concurrent)
    private let baseURL = "http://localhost:11434"

    public var isAvailable: Bool = false
    public var isFirstRequest: Bool = true

    public init(session: URLSession = .shared, logger: Logger) {
        self.session = session
        self.logger = logger
    }

    // Check if Ollama is reachable. Calls completion when done.
    public func checkAvailability(completion: (() -> Void)? = nil) {
        guard let url = URL(string: "\(baseURL)/api/tags") else { completion?(); return }
        let task = session.dataTask(with: url) { [weak self] _, response, error in
            guard let self else { return }
            if error != nil || (response as? HTTPURLResponse)?.statusCode != 200 {
                self.isAvailable = false
                self.logger.log(source: "system", message: "[error] Ollama not running at \(self.baseURL) — vision inference disabled")
            } else {
                self.isAvailable = true
                self.isFirstRequest = true  // reset cold-start flag on reconnect
            }
            completion?()
        }
        task.resume()
    }

    // Start periodic availability recheck every 30 seconds
    public func startRecheckTimer() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.checkAvailability()
            self?.startRecheckTimer()
        }
    }

    // Analyze a JPEG frame from the given source
    public func analyze(jpegData: Data, source: String, completion: (() -> Void)? = nil) {
        guard isAvailable else { completion?(); return }
        guard semaphore.wait(timeout: .now()) == .success else {
            completion?()
            return  // inference queue full, drop this frame
        }

        inferenceQueue.async { [weak self] in
            defer {
                self?.semaphore.signal()
                completion?()
            }
            self?.sendRequest(jpegData: jpegData, source: source)
        }
    }

    private func sendRequest(jpegData: Data, source: String) {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return }

        let timeout = isFirstRequest ? 15.0 : 5.0
        isFirstRequest = false

        let base64Image = jpegData.base64EncodedString()
        let body: [String: Any] = [
            "model": "moondream",
            "prompt": "Describe the person and their activity in 1-2 sentences.",
            "images": [base64Image],
            "stream": false
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { [weak self] data, _, error in
            defer { semaphore.signal() }
            if error != nil {
                self?.logger.log(source: source, message: "[warn] inference timeout (source: \(source))")
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? String else { return }
            self?.logger.log(source: source, message: response.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        task.resume()
        semaphore.wait()
    }
}
