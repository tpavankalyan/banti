import Foundation

enum AXChangeKind: String, Sendable {
    case focusChanged       // user moved focus to a different element
    case selectionChanged   // user selected/deselected text in current element
    case valueChanged       // element value changed (typing)
    case appSwitched        // first event after app switch (synthetic)
}

struct AXFocusEvent: PerceptionEvent {
    let id: UUID
    let timestamp: Date
    let sourceModule: ModuleID              // "ax-focus"

    // App context
    let appName: String
    let bundleIdentifier: String

    // Element context
    let elementRole: String
    let elementTitle: String?
    let windowTitle: String?

    // Selection (nil if nothing selected or text exceeds AX_SELECTED_TEXT_MAX_CHARS)
    let selectedText: String?
    let selectedTextLength: Int             // 0 if no selection

    // What triggered this event
    let changeKind: AXChangeKind
}
