import ApplicationServices
import CoreGraphics

// MARK: - Accessibility helpers
//
// Thin wrappers around the C AX API so callers read top-to-bottom. Everything
// here deals in raw AXUIElement values pulled from the focused app.

enum AX {
    /// How long any single AX call may block. These are synchronous IPC into
    /// another app; the system default is multiple seconds, so one busy or
    /// beachballing target would freeze our overlay, pill, card and menu bar
    /// along with it. Bounded, a slow answer costs a dropped frame instead.
    private static let messagingTimeout: Float = 0.15

    /// One system-wide element, not one per call: creating it is not free and
    /// `focusedElement()` runs several times per tick.
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }()

    /// Copy a plain attribute (value, role, position, size, …) off an element.
    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    /// The element that currently has keyboard focus, system-wide.
    static func focusedElement() -> AXUIElement? {
        guard let raw = copy(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        // The timeout is per element, so it has to be set on each one we take.
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    /// Whether the element sits inside web page content (an AXWebArea ancestor)
    /// rather than browser chrome like the address bar. Locale- and
    /// browser-independent: every engine exposes page content under a web area.
    static func isInWebArea(_ element: AXUIElement) -> Bool {
        // Eight levels is well past any real contenteditable; the old limit of
        // 30 meant browser chrome walked all 30 (two IPC calls each) to answer
        // "no", every tick.
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let el = current else { return false }
            if string(el, kAXRoleAttribute) == "AXWebArea" { return true }
            guard let parent = copy(el, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }

    /// On-screen frame of an element, in global (top-left origin) display coords.
    /// Whether text in this element can actually be edited. A web area, a static
    /// label or a rendered email body is readable but not writable — Nib has
    /// nothing to offer there, and no way to apply it if it did.
    static func isEditable(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute) ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) {
            return true
        }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard
            let posVal = copy(element, kAXPositionAttribute),
            let sizeVal = copy(element, kAXSizeAttribute),
            CFGetTypeID(posVal) == AXValueGetTypeID(),
            CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// Screen bounds for a character range — the parameterized attribute that
    /// makes inline overlays possible. Returns nil if the element doesn't
    /// support it (many custom/Electron editors don't).
    static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let axRange = AXValueCreate(.cfRange, &mutableRange) else { return nil }

        var result: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &result
        )
        guard err == .success, let result,
              CFGetTypeID(result) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        AXValueGetValue(result as! AXValue, .cgRect, &rect)
        // Some web fields return success with an empty {0,0,0,0} rect — that's
        // "no geometry", not a real position at the screen origin.
        return rect.isEmpty ? nil : rect
    }

    /// Screen bounds of the current selection via WebKit-style text markers —
    /// the channel VoiceOver uses. Chromium/Electron implement it even where
    /// index-based AXBoundsForRange fails, so it's the reliable path for
    /// caret/selection geometry in web content.
    static func selectionMarkerBounds(_ element: AXUIElement) -> CGRect? {
        guard let markerRange = copy(element, "AXSelectedTextMarkerRange") else { return nil }
        var value: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &value)
        guard err == .success, let v = value,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect),
              rect.height > 0, rect.height < 500 else { return nil }
        return rect
    }

    /// The current selection/caret as a character range.
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = copy(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        AXValueGetValue(value as! AXValue, .cfRange, &range)
        return range
    }
}
