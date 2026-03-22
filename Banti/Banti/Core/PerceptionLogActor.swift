// Banti/Banti/Core/PerceptionLogActor.swift
import Foundation

// MARK: - Value types

enum PerceptionLogKind: Equatable {
    case screenDescription, sceneDescription, transcript, appSwitch, axFocus
}

struct PerceptionLogEntry {
    var timestamp: Date
    let kind: PerceptionLogKind
    let summary: String
    let changeDistance: Float?
}

struct PerceptionLog {
    let entries: [PerceptionLogEntry]
    let activeApp: ActiveAppEvent?
    let axFocus: AXFocusEvent?
    let recentWindowSeconds: TimeInterval

    func formatted() -> String {
        let now = Date()
        let cutoff = now.addingTimeInterval(-recentWindowSeconds)
        let older = entries.filter { $0.timestamp < cutoff }
        let recent = entries.filter { $0.timestamp >= cutoff }

        var lines: [String] = []

        if !older.isEmpty {
            lines.append("=== Perception Log — Older (>\(Int(recentWindowSeconds))s) ===")
            for e in older { lines.append(formatEntry(e, now: now)) }
        }
        if !recent.isEmpty {
            lines.append("=== Perception Log — Recent (<\(Int(recentWindowSeconds))s) ===")
            for e in recent { lines.append(formatEntry(e, now: now)) }
        }

        lines.append("=== Active Now ===")
        if let app = activeApp { lines.append("App: \(app.appName) (\(app.bundleIdentifier))") }
        if let ax = axFocus {
            var line = "Focus: \(ax.elementRole)"
            if let t = ax.elementTitle { line += " — \(t)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func formatEntry(_ e: PerceptionLogEntry, now: Date) -> String {
        let age = max(0, Int(now.timeIntervalSince(e.timestamp)))
        let kindStr: String
        switch e.kind {
        case .screenDescription: kindStr = "SCREEN     "
        case .sceneDescription:  kindStr = "SCENE      "
        case .transcript:        kindStr = "TRANSCRIPT "
        case .appSwitch:         kindStr = "APP        "
        case .axFocus:           kindStr = "AX_FOCUS   "
        }
        var line = "[\(String(format: "%3d", age))s ago] \(kindStr)"
        if let d = e.changeDistance { line += " dist=\(String(format: "%.2f", d))" }
        line += " | \(e.summary)"
        return line
    }
}

// MARK: - Thread-safe snapshot box

private final class PerceptionLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [PerceptionLogEntry] = []
    private var _activeApp: ActiveAppEvent?
    private var _axFocus: AXFocusEvent?
    var recentWindowSeconds: TimeInterval

    init(recentWindowSeconds: TimeInterval) {
        self.recentWindowSeconds = recentWindowSeconds
    }

    func snapshot() -> PerceptionLog {
        lock.lock(); defer { lock.unlock() }
        return PerceptionLog(entries: _entries, activeApp: _activeApp,
                             axFocus: _axFocus, recentWindowSeconds: recentWindowSeconds)
    }

    func updateEntries(_ block: (inout [PerceptionLogEntry]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        block(&_entries)
    }

    func setActiveApp(_ app: ActiveAppEvent) {
        lock.lock(); defer { lock.unlock() }
        _activeApp = app
    }

    func setAXFocus(_ ax: AXFocusEvent) {
        lock.lock(); defer { lock.unlock() }
        _axFocus = ax
    }
}

// MARK: - Actor

actor PerceptionLogActor: BantiModule {
    nonisolated let id = ModuleID("perception-log")
    nonisolated let capabilities: Set<Capability> = []

    private let eventHub: EventHubActor
    private let windowSeconds: TimeInterval
    private let maxEntries: Int
    nonisolated let recentWindowSeconds: TimeInterval

    private let box: PerceptionLogBox
    private var subscriptionIDs: [SubscriptionID] = []
    private var _health: ModuleHealth = .healthy

    init(eventHub: EventHubActor,
         windowSeconds: TimeInterval = 90,
         maxEntries: Int = 50,
         recentWindowSeconds: TimeInterval = 30) {
        self.eventHub = eventHub
        self.windowSeconds = windowSeconds
        self.maxEntries = maxEntries
        self.recentWindowSeconds = recentWindowSeconds
        self.box = PerceptionLogBox(recentWindowSeconds: recentWindowSeconds)
    }

    func start() async throws {
        subscriptionIDs.append(await eventHub.subscribe(ScreenDescriptionEvent.self) { [weak self] e in await self?.handle(e) })
        subscriptionIDs.append(await eventHub.subscribe(SceneDescriptionEvent.self)  { [weak self] e in await self?.handle(e) })
        subscriptionIDs.append(await eventHub.subscribe(TranscriptSegmentEvent.self) { [weak self] e in await self?.handle(e) })
        subscriptionIDs.append(await eventHub.subscribe(ActiveAppEvent.self)         { [weak self] e in await self?.handle(e) })
        subscriptionIDs.append(await eventHub.subscribe(AXFocusEvent.self)           { [weak self] e in await self?.handle(e) })
        _health = .healthy
    }

    func stop() async {
        for s in subscriptionIDs { await eventHub.unsubscribe(s) }
        subscriptionIDs.removeAll()
    }

    func health() async -> ModuleHealth { _health }

    nonisolated func log() -> PerceptionLog {
        box.snapshot()
    }

    // MARK: - Handlers

    private func handle(_ e: ScreenDescriptionEvent) {
        insert(PerceptionLogEntry(timestamp: e.timestamp, kind: .screenDescription,
                                  summary: e.text, changeDistance: e.changeDistance))
    }

    private func handle(_ e: SceneDescriptionEvent) {
        insert(PerceptionLogEntry(timestamp: e.timestamp, kind: .sceneDescription,
                                  summary: e.text, changeDistance: Float?(e.changeDistance)))
    }

    private func handle(_ e: TranscriptSegmentEvent) {
        guard e.isFinal else { return }
        insert(PerceptionLogEntry(timestamp: e.timestamp, kind: .transcript,
                                  summary: "user: \(e.text)", changeDistance: nil))
    }

    private func handle(_ e: ActiveAppEvent) {
        box.setActiveApp(e)
        insert(PerceptionLogEntry(timestamp: e.timestamp, kind: .appSwitch,
                                  summary: "\(e.appName) (\(e.bundleIdentifier))", changeDistance: nil))
    }

    private func handle(_ e: AXFocusEvent) {
        box.setAXFocus(e)
        // Dedup: only skip if all three fields are non-nil and match last axFocus entry
        let snapshot = box.snapshot()
        if let last = snapshot.entries.last(where: { $0.kind == .axFocus }),
           let title = e.elementTitle,
           last.summary.contains(e.appName),
           last.summary.contains(e.elementRole),
           last.summary.contains(title) {
            // Update timestamp in-place
            box.updateEntries { entries in
                if let idx = entries.lastIndex(where: { $0.kind == .axFocus }) {
                    entries[idx].timestamp = e.timestamp
                }
            }
            return
        }
        var summary = "\(e.appName) — \(e.elementRole)"
        if let t = e.elementTitle { summary += " \"\(t)\"" }
        insert(PerceptionLogEntry(timestamp: e.timestamp, kind: .axFocus,
                                  summary: summary, changeDistance: nil))
    }

    // MARK: - Insertion with eviction

    private func insert(_ entry: PerceptionLogEntry) {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        let cap = maxEntries
        box.updateEntries { entries in
            // Age-evict first
            entries.removeAll { $0.timestamp < cutoff }
            entries.append(entry)
            // Cap after age-evict
            if entries.count > cap {
                entries.removeFirst(entries.count - cap)
            }
        }
    }
}
