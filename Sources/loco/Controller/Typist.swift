import Cocoa

/// Synthetic-keyboard write-back for editors that ignore AX text writes
/// (Chromium/Electron — Slack above all). Runs OFF the main thread: every step
/// waits on the editor. Never touches the clipboard.
///
/// Slack's editor batches and reorders input, resets the caret between
/// inputs, and a single event longer than ~20 UTF-16 units can consume the
/// selection and insert nothing — so text goes in ≤20-unit chunks, each at a
/// caret re-pinned by an AX range write (which Slack does honor).
struct Typist: @unchecked Sendable {
    let watched: AXBox?
    private let source = CGEventSource(stateID: .combinedSessionState)

    init(element: AXUIElement?) {
        watched = element.map { AXBox(element: $0) }
    }

    func post(_ units: [UInt16]) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.post(tap: .cghidEventTap)
    }

    /// Forward-delete-free deletion of the current selection.
    func backspace() {
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down)?
                .post(tap: .cghidEventTap)
        }
    }

    func value() -> String {
        watched.map { AX.string($0.element, kAXValueAttribute) ?? "" } ?? ""
    }

    @discardableResult
    func waitForChange(from before: String, upTo: Int = 40) -> Bool {
        for _ in 0..<upTo {
            usleep(15_000)
            if value() != before { return true }
        }
        return false
    }

    func pinSelection(_ sel: NSRange) {
        guard let watched else { return }
        var cf = CFRange(location: sel.location, length: sel.length)
        if let axRange = AXValueCreate(.cfRange, &cf) {
            AXUIElementSetAttributeValue(watched.element,
                                         kAXSelectedTextRangeAttribute as CFString, axRange)
            usleep(30_000)
        }
    }

    /// Type `units` over `selection` (nil: at the current caret/selection).
    func pinnedType(_ units: [UInt16], over selection: NSRange?) {
        var caret = selection?.location ?? 0
        var start = 0
        while start < units.count {
            let chunk = Array(units[start..<min(start + 20, units.count)])
            if start == 0, let sel = selection {
                pinSelection(sel)
            } else if start > 0, watched != nil {
                pinSelection(NSRange(location: caret, length: 0))
            }
            let before = value()
            post(chunk)
            Log.debug(.action, "pinned chunk posted", [
                "chunk": String(utf16CodeUnits: chunk, count: chunk.count),
                "caret": caret,
            ])
            if watched != nil { waitForChange(from: before) } else { usleep(15_000) }
            caret = (start == 0 ? (selection?.location ?? 0) : caret) + chunk.count
            start += 20
        }
    }

    /// Replace `range` with `text`: type over it, or delete it when `text` is
    /// empty.
    func replace(_ range: NSRange, with text: String) {
        if text.isEmpty {
            guard range.length > 0 else { return }
            pinSelection(range)
            let before = value()
            backspace()
            if watched != nil { waitForChange(from: before) }
        } else {
            pinnedType(Array(text.utf16), over: range)
        }
    }

    private static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Settle, compare with `expected`, and repair once — retyping only the
    /// region that differs, and never across a link (retyping a link's text
    /// turns it into plain text). Newlines are ignored in the comparison:
    /// Slack's AX value renders paragraph breaks inconsistently right after
    /// an edit.
    func verifyAndRepair(expected: String) {
        guard let watched else { return }
        usleep(350_000)
        let settled = value()
        if Self.normalized(settled) == Self.normalized(expected) {
            Log.info(.action, "write-back verified on attempt 1", [:])
            return
        }
        let s = Array(settled.utf16), e = Array(expected.utf16)
        var p = 0
        while p < s.count, p < e.count, s[p] == e[p] { p += 1 }
        var q = 0
        while q < s.count - p, q < e.count - p, s[s.count - 1 - q] == e[e.count - 1 - q] { q += 1 }
        let region = NSRange(location: p, length: s.count - p - q)
        let fix = String(utf16CodeUnits: Array(e[p..<(e.count - q)]), count: e.count - p - q)
        let links = AX.linkRanges(watched.element, in: settled)
        if TextHunks.overlaps(region, links) {
            Log.warn(.action, "write-back mismatch left alone", [
                "reason": "repair would retype a link",
                "settled": String(settled.prefix(120)),
                "expected": String(expected.prefix(120)),
            ])
            return
        }
        Log.warn(.action, "write-back mismatch, repairing the differing region", [
            "region": "\(region.location)+\(region.length)",
            "fix": String(fix.prefix(60)),
        ])
        replace(region, with: fix)
        usleep(350_000)
        let repaired = value()
        if Self.normalized(repaired) == Self.normalized(expected) {
            Log.info(.action, "write-back verified on attempt 2", [:])
        } else {
            Log.warn(.action, "write-back corrupted after repair", [
                "value": String(repaired.prefix(160)),
            ])
        }
    }
}
