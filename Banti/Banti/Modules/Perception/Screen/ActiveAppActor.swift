import Foundation
import AppKit
import os

actor ActiveAppActor: BantiModule {
    nonisolated let id = ModuleID("active-app")
    nonisolated let capabilities: Set<Capability> = [.activeAppTracking]

    private let logger = Logger(subsystem: "com.banti.active-app", category: "ActiveApp")
    private let eventHub: EventHubActor

    private var observer: NSObjectProtocol?
    private var currentBundleID: String?
    private var currentAppName: String?
    private var _health: ModuleHealth = .healthy

    init(eventHub: EventHubActor) {
        self.eventHub = eventHub
    }

    func start() async throws {
        // Publish initial snapshot for the current frontmost app.
        await publishCurrentApp(previous: nil)

        let hub = eventHub
        let actorRef = self

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak actorRef] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { await actorRef?.handleActivation(of: app) }
            _ = hub  // retain hub reference in the closure
        }

        _health = .healthy
        logger.notice("ActiveAppActor started")
    }

    func stop() async {
        if let obs = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            observer = nil
        }
        currentBundleID = nil
        currentAppName = nil
    }

    func health() async -> ModuleHealth { _health }

    // Called from the notification closure (off-actor, via Task).
    func handleActivation(of app: NSRunningApplication) async {
        let bundleID = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName ?? "unknown"

        // Skip if the same app is still frontmost (e.g. window focus within same app).
        guard bundleID != currentBundleID else { return }

        let previousBundle = currentBundleID
        let previousName = currentAppName

        currentBundleID = bundleID
        currentAppName = appName

        let event = ActiveAppEvent(
            bundleIdentifier: bundleID,
            appName: appName,
            previousBundleIdentifier: previousBundle,
            previousAppName: previousName
        )
        await eventHub.publish(event)
        logger.debug("App switched: \(appName, privacy: .public) (\(bundleID, privacy: .public))")
    }

    private func publishCurrentApp(previous: NSRunningApplication?) async {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        let bundleID = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName ?? "unknown"

        currentBundleID = bundleID
        currentAppName = appName

        let event = ActiveAppEvent(
            bundleIdentifier: bundleID,
            appName: appName,
            previousBundleIdentifier: nil,
            previousAppName: nil
        )
        await eventHub.publish(event)
        logger.notice("Initial active app: \(appName, privacy: .public)")
    }
}
