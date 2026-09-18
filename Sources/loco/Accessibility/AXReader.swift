import AppKit
import ApplicationServices

/// A CF accessibility reference carried across threads. The AX C API is
/// documented thread-safe; Swift can't prove that for a CFTypeRef, hence the
/// unchecked box.
struct AXBox: @unchecked Sendable {
    let element: AXUIElement
}

/// Same, for an AXObserver: registration calls (each an IPC round-trip) run on
/// the reader queue; only its runloop source lives on the main runloop.
struct AXObserverBox: @unchecked Sendable {
    let observer: AXObserver
}

/// Everything one detection pass needs to know about the focused field, read in
/// a single burst OFF the main thread. Each AX getter is a synchronous IPC
/// round-trip that can take up to the messaging timeout when the target app is
/// busy — profiled at 60–1000ms bursts, which on the main thread froze whatever
/// the overlay was animating. Reading here costs the same time, but nobody sees
/// it: the main thread only ever touches finished values.
struct FieldSnapshot: Sendable {
    let element: AXBox
    /// The pid that owns the element (may differ from the frontmost app for
    /// system overlays like Spotlight).
    let ownerPid: pid_t?
    let role: String
    let value: String
    let frame: CGRect?
    /// Only computed for browser hosts (the expensive ancestor walk): whether
    /// the element sits in page content rather than browser chrome.
    let inWebArea: Bool?
    /// Only computed for browser hosts: whether text can be typed into it.
    let textEditable: Bool?
}

/// Raw material for one selection-pill pass, read off the main thread. Rects
/// are raw AX (top-left) coordinates; every conversion and decision stays on
/// the main side, so this is purely the IPC burst.
struct SelectionRead: Sendable {
    let element: AXBox
    let axFrame: CGRect
    let inWebArea: Bool?
    let selectedText: String?
    let selectedRange: NSRange?
    let fullValue: String?
    /// AX.bounds(of: selection) — the index-based answer (empty in Chromium).
    let selectionBounds: CGRect?
    /// The text-marker (VoiceOver channel) answer — works in Chromium/Electron.
    let markerBounds: CGRect?
    /// Bounds of the selection's first character (line-height yardstick).
    let firstCharBounds: CGRect?
    /// Caret-range bounds, for the no-selection branch.
    let caretBounds: CGRect?
    /// Chromium's degraded answer: the "focused element" is the whole web area
    /// (its focus attribute returns itself). Selection reads still work against
    /// it, but write-back must go through the browser DOM route, and only an
    /// explicit selection is trustworthy (the web area's value is the whole
    /// page, so caret-sentence extraction would read page text, not the field).
    let degradedWebArea: Bool
}

enum AXReader {
    /// A short human identity for an element, for diagnosing "wrong node" bugs:
    /// role, frame, and the first characters of its value.
    static func describe(_ el: AXUIElement) -> String {
        let role = AX.string(el, kAXRoleAttribute) ?? "?"
        let frame = AX.frame(el).map { NSStringFromRect($0) } ?? "no-frame"
        let value = (AX.string(el, kAXValueAttribute) ?? "").prefix(24)
        return "\(role) @\(frame) \"\(value)\""
    }

    /// Serial, so at most one read burst is in flight and results arrive in
    /// order. userInitiated: the result drives visible UI.
    static let queue = DispatchQueue(label: "nib.ax.read", qos: .userInitiated)

    /// The focused element, resolved one level: Chromium sometimes answers the
    /// system-wide query with the whole AXWebArea (typically after key-window
    /// transitions) even though a field inside it has focus — asking the web
    /// area for ITS focused element yields the real field.
    private static func resolveFocused() -> AXUIElement? {
        guard let el = AX.focusedElement() else { return nil }
        if AX.string(el, kAXRoleAttribute) == "AXWebArea",
           let raw = AX.copy(el, kAXFocusedUIElementAttribute as String),
           CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return (raw as! AXUIElement)
        }
        return el
    }

    /// The focused element plus everything the tick needs about it.
    /// `browserHost` gates the web-area/editability walks; `cachedWebArea` is
    /// the previous walk's answer for the same element, if any.
    static func readFocusedField(browserHost: Bool,
                                 cachedWebArea: (AXBox, Bool)?) -> FieldSnapshot? {
        guard let el = resolveFocused() else { return nil }
        var pid: pid_t = 0
        let ownerPid: pid_t? = AXUIElementGetPid(el, &pid) == .success ? pid : nil
        let role = AX.string(el, kAXRoleAttribute) ?? "?"
        let value = AX.string(el, kAXValueAttribute) ?? ""
        let frame = AX.frame(el)
        var inWeb: Bool?
        var editable: Bool?
        if browserHost {
            if let cached = cachedWebArea, CFEqual(cached.0.element, el) {
                inWeb = cached.1
            } else {
                inWeb = AX.isInWebArea(el)
            }
            editable = AX.isTextEditable(el)
        }
        return FieldSnapshot(element: AXBox(element: el), ownerPid: ownerPid,
                             role: role, value: value, frame: frame,
                             inWebArea: inWeb, textEditable: editable)
    }

    /// The selection-pill read burst: focused element, its frame/editability,
    /// the selection (or caret) and every geometry answer the pill placement
    /// can fall back through. Returns nil when there's no editable focus —
    /// same cases the old main-thread guard hid the pill for.
    static func readSelection(browserHost: Bool,
                              cachedWebArea: (AXBox, Bool)?) -> SelectionRead? {
        guard let el = resolveFocused() else {
            Log.debug(.ax, "selection read failed", ["reason": "no focused element"])
            return nil
        }
        guard let frame = AX.frame(el) else {
            Log.debug(.ax, "selection read failed", [
                "reason": "no frame", "role": AX.string(el, kAXRoleAttribute) ?? "?",
            ])
            return nil
        }
        let role = AX.string(el, kAXRoleAttribute) ?? "?"
        let degraded = browserHost && role == "AXWebArea"
        guard AX.isEditable(el) || degraded else {
            Log.debug(.ax, "selection read failed", ["reason": "not editable", "role": role])
            return nil
        }
        var inWeb: Bool?
        if browserHost {
            if let cached = cachedWebArea, CFEqual(cached.0.element, el) {
                inWeb = cached.1
            } else {
                inWeb = AX.isInWebArea(el)
            }
        }
        var selText: String?
        var selRange: NSRange?
        var fullValue: String?
        var selBounds: CGRect?
        var marker: CGRect?
        var firstChar: CGRect?
        var caret: CGRect?
        if let cf = AX.selectedRange(el) {
            selRange = NSRange(location: cf.location, length: cf.length)
            fullValue = AX.string(el, kAXValueAttribute)
            if cf.length > 0 {
                selText = AX.string(el, kAXSelectedTextAttribute)
                let first = CFRange(location: cf.location, length: min(1, max(0, cf.length)))
                selBounds = AX.bounds(of: cf, in: el)
                marker = AX.selectionMarkerBounds(el)
                firstChar = AX.bounds(of: first, in: el)
            } else {
                marker = AX.selectionMarkerBounds(el)
                let loc = max(0, cf.location)
                caret = AX.bounds(of: CFRange(location: loc, length: 0), in: el)
            }
        }
        // Degraded web area with no actual selection: nothing trustworthy to
        // read (the web area's "value" is the whole page).
        if degraded, (selRange?.length ?? 0) == 0 {
            Log.debug(.ax, "selection read failed", ["reason": "web area focus, no selection"])
            return nil
        }
        return SelectionRead(element: AXBox(element: el), axFrame: frame,
                             inWebArea: inWeb, selectedText: selText,
                             selectedRange: selRange, fullValue: fullValue,
                             selectionBounds: selBounds, markerBounds: marker,
                             firstCharBounds: firstChar, caretBounds: caret,
                             degradedWebArea: degraded)
    }
}
