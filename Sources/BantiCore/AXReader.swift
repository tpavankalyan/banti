// Sources/banti/AXReader.swift
import ApplicationServices
import Foundation

public final class AXReader {
    private let logger: Logger
    private var observer: AXObserver?
    private var currentApp: AXUIElement?

    public init(logger: Logger) {
        self.logger = logger
    }

    // Returns false if permission is not granted
    @discardableResult
    public func start() -> Bool {
        guard AXIsProcessTrusted() else {
            logger.log(source: "system", message: "[error] Accessibility permission not granted — AX reader disabled")
            return false
        }
        setupObserver()
        return true
    }

    private func setupObserver() {
        // Use PID 0 to create a system-wide observer capable of observing all apps
        var obs: AXObserver?
        AXObserverCreate(0, { _, _, _, userData in
            guard let ptr = userData else { return }
            let reader = Unmanaged<AXReader>.fromOpaque(ptr).takeUnretainedValue()
            reader.onFocusChange()
        }, &obs)

        guard let obs else { return }
        observer = obs

        let notifications = [
            kAXFocusedWindowChangedNotification,
            kAXApplicationActivatedNotification
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let systemWide = AXUIElementCreateSystemWide()

        for notification in notifications {
            AXObserverAddNotification(obs, systemWide, notification as CFString, selfPtr)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        onFocusChange()  // capture initial state
    }

    private func onFocusChange() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        guard let app = focusedApp else { return }

        var appName: CFTypeRef?
        AXUIElementCopyAttributeValue(app as! AXUIElement, kAXTitleAttribute as CFString, &appName)

        var focusedWindow: CFTypeRef?
        AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        var windowTitle = "unknown window"
        if let window = focusedWindow {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
            if let t = title as? String { windowTitle = t }
        }

        var elements: [String] = []
        if let window = focusedWindow {
            walk(element: window as! AXUIElement, depth: 0, maxDepth: 3, maxElements: 50, results: &elements)
        }

        let summary = [
            "app: \(appName as? String ?? "unknown")",
            "window: \(windowTitle)",
            elements.isEmpty ? nil : "elements: \(elements.joined(separator: " | "))"
        ].compactMap { $0 }.joined(separator: ", ")

        _ = summary
    }

    private func walk(element: AXUIElement, depth: Int, maxDepth: Int, maxElements: Int, results: inout [String]) {
        guard depth < maxDepth, results.count < maxElements else { return }

        var role: CFTypeRef?
        var title: CFTypeRef?
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)

        let parts = [role as? String, title as? String, value as? String].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            results.append(parts.joined(separator: ":"))
        }

        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard let childList = children as? [AXUIElement] else { return }
        for child in childList {
            walk(element: child, depth: depth + 1, maxDepth: maxDepth, maxElements: maxElements, results: &results)
        }
    }
}
