import ApplicationServices
import CoreGraphics

// MARK: - Accessibility helpers
//
// Thin wrappers around the C AX API so callers read top-to-bottom. Everything
// here deals in raw AXUIElement values pulled from the focused app.

enum AX {
    /// Copy a plain attribute (value, role, position, size, …) off an element.
    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    /// The element that currently has keyboard focus, system-wide.
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let raw = copy(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    /// Whether the element sits inside web page content (an AXWebArea ancestor)
    /// rather than browser chrome like the address bar. Locale- and
    /// browser-independent: every engine exposes page content under a web area.
    static func isInWebArea(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<30 {
            guard let el = current else { return false }
            if string(el, kAXRoleAttribute) == "AXWebArea" { return true }
            guard let parent = copy(el, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }

    /// On-screen frame of an element, in global (top-left origin) display coords.
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

    /// The current selection/caret as a character range.
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = copy(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        AXValueGetValue(value as! AXValue, .cfRange, &range)
        return range
    }
}
