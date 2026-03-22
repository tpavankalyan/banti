import Foundation

struct ActiveAppEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID
    let bundleIdentifier: String
    let appName: String
    let previousBundleIdentifier: String?
    let previousAppName: String?

    init(
        bundleIdentifier: String,
        appName: String,
        previousBundleIdentifier: String?,
        previousAppName: String?
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.sourceModule = ModuleID("active-app")
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.previousBundleIdentifier = previousBundleIdentifier
        self.previousAppName = previousAppName
    }
}
