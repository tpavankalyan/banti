import Foundation
import ApplicationServices

/// Non-isolated bridge between the C AXObserver callback and AXFocusActor.
/// The C callback runs on the main run loop; this class schedules async Tasks
/// so attribute reading happens off the main thread inside the actor.
final class AXEventBridge: @unchecked Sendable {
    private weak var actor: AXFocusActor?

    init(actor: AXFocusActor) {
        self.actor = actor
    }

    func notify(pid: pid_t, notification: String) {
        guard let actor else { return }
        Task { await actor.handleNotification(pid: pid, notification: notification) }
    }
}

/// C-compatible callback required by AXObserverCreate.
/// Extracts the pid from the element and forwards to AXEventBridge.
func axObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let bridge = Unmanaged<AXEventBridge>.fromOpaque(refcon).takeUnretainedValue()
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    bridge.notify(pid: pid, notification: notification as String)
}
