import Foundation
import ApplicationServices
import AppKit
import os

actor AXFocusActor: BantiModule {
    nonisolated let id = ModuleID("ax-focus")
    nonisolated let capabilities: Set<Capability> = [.axObservation]

    private let logger = Logger(subsystem: "com.banti.ax-focus", category: "AXFocus")
    private let eventHub: EventHubActor
    private let config: ConfigActor

    private var debounceMs: Int = 50
    private var selectedTextMaxChars: Int = 2000

    // AXObserver for the currently frontmost app
    private var currentObserver: AXObserver?
    private var currentPid: pid_t = 0
    private var currentBridgeRef: Unmanaged<AXEventBridge>?

    // Debounce task for valueChanged events
    private var pendingValueTask: Task<Void, Never>?

    // EventHub subscription
    private var activeAppSubID: SubscriptionID?
    private var workspaceObserver: NSObjectProtocol?

    // Health tracking for high-error-rate degradation
    private var recentErrorDates: [Date] = []
    private var recentCallCount: Int = 0
    private let errorRateWindow: TimeInterval = 10
    private let errorRateThreshold: Double = 0.2

    private var _health: ModuleHealth = .healthy

    init(eventHub: EventHubActor, config: ConfigActor) {
        self.eventHub = eventHub
        self.config = config
    }

    // MARK: - BantiModule

    func start() async throws {
        debounceMs = Int((await config.value(for: EnvKey.axDebounceMs))
            .flatMap(Int.init) ?? 50)
        selectedTextMaxChars = Int((await config.value(for: EnvKey.axSelectedTextMaxChars))
            .flatMap(Int.init) ?? 2000)

        // Check accessibility permission. Per spec: no retry on permission failure.
        guard AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        ) else {
            let err = AXPermissionError.notGranted
            _health = .failed(error: err)
            throw err
        }

        // Subscribe to ActiveAppEvent for efficient observer re-registration.
        activeAppSubID = await eventHub.subscribe(ActiveAppEvent.self) { [weak self] event in
            guard let self else { return }
            await self.handleActiveAppEvent(event)
        }

        // Fallback: NSWorkspace notification in case ActiveAppEvent is not published.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let self else { return }
            let pid = app.processIdentifier
            Task { await self.registerObserver(forPid: pid) }
        }

        // Bootstrap with the current frontmost app.
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            await registerObserver(forPid: frontmost.processIdentifier)
        }

        _health = .healthy
        logger.notice("AXFocusActor started (debounceMs=\(self.debounceMs), maxChars=\(self.selectedTextMaxChars))")
    }

    func stop() async {
        pendingValueTask?.cancel()
        pendingValueTask = nil

        removeCurrentObserver()

        if let subID = activeAppSubID {
            await eventHub.unsubscribe(subID)
            activeAppSubID = nil
        }

        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
        logger.notice("AXFocusActor stopped")
    }

    func health() async -> ModuleHealth { _health }

    // MARK: - Observer management

    /// Called by AXEventBridge when a notification arrives from the AXObserver callback.
    func handleNotification(pid: pid_t, notification: String) async {
        let changeKind: AXChangeKind
        switch notification {
        case kAXFocusedUIElementChangedNotification:
            changeKind = .focusChanged
        case kAXSelectedTextChangedNotification:
            changeKind = .selectionChanged
        case kAXValueChangedNotification:
            changeKind = .valueChanged
        default:
            return
        }

        if changeKind == .valueChanged {
            // Debounce rapid keystrokes.
            pendingValueTask?.cancel()
            pendingValueTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(self.debounceMs))
                guard !Task.isCancelled else { return }
                await self.publishCurrentFocus(pid: pid, changeKind: .valueChanged)
            }
        } else {
            // focusChanged and selectionChanged are published immediately.
            await publishCurrentFocus(pid: pid, changeKind: changeKind)
        }
    }

    private func handleActiveAppEvent(_ event: ActiveAppEvent) async {
        // Resolve bundleIdentifier to a running app pid.
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == event.bundleIdentifier
        }) else { return }
        await registerObserver(forPid: app.processIdentifier)
    }

    private func registerObserver(forPid pid: pid_t) async {
        guard pid != currentPid else { return }
        // Never observe our own process — it would create a feedback loop as the UI re-renders.
        guard pid != pid_t(ProcessInfo.processInfo.processIdentifier) else { return }
        removeCurrentObserver()
        currentPid = pid

        let bridge = AXEventBridge(actor: self)
        let bridgeRef = Unmanaged.passRetained(bridge)
        let bridgePtr = bridgeRef.toOpaque()
        currentBridgeRef = bridgeRef

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &observer)
        guard result == .success, let obs = observer else {
            logger.warning("AXObserverCreate failed for pid=\(pid, privacy: .public): \(result.rawValue)")
            currentBridgeRef?.release()
            currentBridgeRef = nil
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(obs, appElement, kAXFocusedUIElementChangedNotification as CFString, bridgePtr)
        AXObserverAddNotification(obs, appElement, kAXSelectedTextChangedNotification as CFString, bridgePtr)
        AXObserverAddNotification(obs, appElement, kAXValueChangedNotification as CFString, bridgePtr)

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )
        currentObserver = obs

        // Synthetic appSwitched event on app change.
        await publishCurrentFocus(pid: pid, changeKind: .appSwitched)
        logger.debug("AXObserver registered for pid=\(pid, privacy: .public)")
    }

    private func removeCurrentObserver() {
        if let obs = currentObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(obs),
                .defaultMode
            )
            currentObserver = nil
        }
        currentBridgeRef?.release()
        currentBridgeRef = nil
        currentPid = 0
    }

    // MARK: - Attribute reading + publishing

    private func publishCurrentFocus(pid: pid_t, changeKind: AXChangeKind) async {
        recentCallCount += 1

        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let appName = app.localizedName ?? "Unknown"
        let bundleID = app.bundleIdentifier ?? ""

        let appElement = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue)

        guard focusResult == .success, let focusedRef = focusedValue else {
            if focusResult != .noValue {
                recordError()
            }
            return
        }

        // swiftlint:disable:next force_cast
        let focusedElement = focusedRef as! AXUIElement

        let role = axString(focusedElement, kAXRoleAttribute) ?? "Unknown"
        let titleAttr = axString(focusedElement, kAXTitleAttribute)
        let descAttr = axString(focusedElement, kAXDescriptionAttribute)
        let title = titleAttr ?? descAttr
        let windowTitle = axWindowTitle(focusedElement)

        let rawSelected = axString(focusedElement, kAXSelectedTextAttribute)
        let selectedLength = rawSelected?.count ?? 0
        let selectedText: String? = rawSelected.flatMap {
            $0.count <= selectedTextMaxChars ? $0 : nil
        }

        let event = AXFocusEvent(
            id: UUID(),
            timestamp: Date(),
            sourceModule: id,
            appName: appName,
            bundleIdentifier: bundleID,
            elementRole: role,
            elementTitle: title,
            windowTitle: windowTitle,
            selectedText: selectedText,
            selectedTextLength: selectedLength,
            changeKind: changeKind
        )
        await eventHub.publish(event)
    }

    // MARK: - Error rate tracking

    private func recordError() {
        let now = Date()
        recentErrorDates.append(now)
        // Prune errors outside the window.
        recentErrorDates = recentErrorDates.filter { now.timeIntervalSince($0) <= errorRateWindow }

        let windowedCalls = max(recentCallCount, 1)
        let errorRate = Double(recentErrorDates.count) / Double(windowedCalls)
        if errorRate > errorRateThreshold {
            _health = .degraded(reason: "AX read error rate \(Int(errorRate * 100))% in last \(Int(errorRateWindow))s")
        }
    }

    // MARK: - AX attribute helpers

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let str = value as? String, !str.isEmpty
        else { return nil }
        return str
    }

    private func axWindowTitle(_ element: AXUIElement) -> String? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
              let windowEl = windowRef
        else { return nil }
        // swiftlint:disable:next force_cast
        return axString(windowEl as! AXUIElement, kAXTitleAttribute)
    }

    // MARK: - Testing seam

    /// Inject a synthetic AXFocusEvent directly into the pipeline.
    /// Applies selectedText truncation, allowing truncation behaviour to be tested
    /// without real AX observation or accessibility permissions.
    func injectEventForTesting(
        changeKind: AXChangeKind,
        appName: String = "TestApp",
        bundleIdentifier: String = "com.test.app",
        elementRole: String = "AXTextField",
        elementTitle: String? = nil,
        windowTitle: String? = nil,
        selectedText: String? = nil,
        selectedTextMaxCharsOverride: Int? = nil
    ) async {
        let maxChars = selectedTextMaxCharsOverride ?? selectedTextMaxChars
        let length = selectedText?.count ?? 0
        let truncated: String? = selectedText.flatMap {
            $0.count <= maxChars ? $0 : nil
        }

        let event = AXFocusEvent(
            id: UUID(),
            timestamp: Date(),
            sourceModule: id,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            elementRole: elementRole,
            elementTitle: elementTitle,
            windowTitle: windowTitle,
            selectedText: truncated,
            selectedTextLength: length,
            changeKind: changeKind
        )
        await eventHub.publish(event)
    }

    /// Inject a valueChanged notification through the debounce path.
    func injectValueChangedForTesting() async {
        pendingValueTask?.cancel()
        pendingValueTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(self.debounceMs))
            guard !Task.isCancelled else { return }
            await self.injectEventForTesting(changeKind: .valueChanged)
        }
    }
}

// MARK: - Permission error

enum AXPermissionError: Error {
    case notGranted
}
