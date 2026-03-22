import Foundation
import os

// MARK: - Client protocol

/// Abstracts the HTTP call to the memory sidecar so tests can inject a stub.
protocol MemoryClient: Sendable {
    func ingestTurn(userText: String, responseText: String) async throws
}

// MARK: - Real sidecar client

/// POSTs a conversation turn to the banti memory sidecar (localhost:7700).
struct SidecarMemoryClient: MemoryClient {
    let baseURL: URL

    static let defaultBaseURL = URL(string: "http://localhost:7700")!

    func ingestTurn(userText: String, responseText: String) async throws {
        let url = baseURL.appendingPathComponent("ingest/turn")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "user_text": userText,
            "response_text": responseText
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MemoryWriteBackError("Sidecar returned \(code)")
        }
    }
}

struct MemoryWriteBackError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Actor

/// Subscribes to AgentResponseEvent and fire-and-forgets each turn to the memory sidecar.
/// Sidecar errors are logged but do not degrade health — the sidecar may not always be running.
actor MemoryWriteBackActor: BantiModule {
    nonisolated let id = ModuleID("memory-write-back")
    nonisolated let capabilities: Set<Capability> = []

    private let eventHub: EventHubActor
    private let memoryClient: any MemoryClient
    private var subscriptionIDs: [SubscriptionID] = []
    private var _health: ModuleHealth = .healthy
    private let logger = Logger(subsystem: "com.banti.memory", category: "WriteBack")

    init(eventHub: EventHubActor, memoryClient: any MemoryClient) {
        self.eventHub = eventHub
        self.memoryClient = memoryClient
    }

    func start() async throws {
        subscriptionIDs.append(await eventHub.subscribe(AgentResponseEvent.self) { [weak self] event in
            await self?.handle(event)
        })
        _health = .healthy
    }

    func stop() async {
        for subID in subscriptionIDs {
            await eventHub.unsubscribe(subID)
        }
        subscriptionIDs.removeAll()
    }

    func health() async -> ModuleHealth { _health }

    // MARK: - Private

    private func handle(_ event: AgentResponseEvent) async {
        do {
            try await memoryClient.ingestTurn(userText: event.userText,
                                              responseText: event.responseText)
            logger.debug("Memory write-back succeeded")
        } catch {
            logger.warning("Memory write-back failed (sidecar may be offline): \(error.localizedDescription, privacy: .public)")
            // Do not degrade health — sidecar is optional infrastructure
        }
    }
}
