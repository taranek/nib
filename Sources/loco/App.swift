import Cocoa
import ApplicationServices
import WebKit
import CursorBounds

// MARK: - Entry point

@main
@MainActor
struct Loco {
    static func main() {
        setbuf(stdout, nil) // unbuffered: logs show even when piped

        let app = NSApplication.shared
        // Accessory: no Dock icon, no menu bar — it's a background overlay agent.
        app.setActivationPolicy(.accessory)

        let controller = AppController()
        controller.start()

        app.run()
    }
}

// MARK: - Accessibility helpers
//
// Thin wrappers around the C AX API so the controller reads top-to-bottom.
// Everything here deals in raw AXUIElement values pulled from the focused app.

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

    /// Names of every plain attribute this element exposes.
    static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// Names of every parameterized attribute (AXBoundsForRange, marker APIs…).
    static func parameterizedAttributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
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

    /// The caret's visual line number (AXInsertionPointLineNumber).
    static func insertionPointLine(_ element: AXUIElement) -> Int? {
        (copy(element, "AXInsertionPointLineNumber") as? NSNumber)?.intValue
    }

    /// Marker range for a visual line number (AXTextMarkerRangeForLine).
    static func textMarkerRange(forLine line: Int, in element: AXUIElement) -> CFTypeRef? {
        let number = line as CFNumber
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXTextMarkerRangeForLine" as CFString, number, &result) == .success,
              let result else { return nil }
        return result
    }

    /// The current selection as a text-marker range (AXSelectedTextMarkerRange).
    static func selectedTextMarkerRange(_ element: AXUIElement) -> CFTypeRef? {
        copy(element, "AXSelectedTextMarkerRange")
    }

    /// Bounds of the element's entire text content (AXTextMarkerRangeForUIElement
    /// → AXBoundsForTextMarkerRange). Used to clamp indicators to real content.
    static func contentRect(_ element: AXUIElement) -> CGRect? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXTextMarkerRangeForUIElement" as CFString, element, &result) == .success,
              let result else { return nil }
        return bounds(forMarkerRange: result, in: element)
    }

    /// The current selection/caret as a character range.
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = copy(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        AXValueGetValue(value as! AXValue, .cfRange, &range)
        return range
    }

    /// The visual line number containing a character index (AXLineForIndex).
    static func lineNumber(forCharIndex index: Int, in element: AXUIElement) -> Int? {
        let number = index as CFNumber
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXLineForIndex" as CFString, number, &result) == .success,
              let result else { return nil }
        return (result as? NSNumber)?.intValue
    }

    /// The character range of a visual line (AXRangeForLine).
    static func range(forLine line: Int, in element: AXUIElement) -> CFRange? {
        let number = line as CFNumber
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXRangeForLine" as CFString, number, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        AXValueGetValue(result as! AXValue, .cfRange, &range)
        return range
    }

    // MARK: Text markers (Chromium/WebKit contenteditable fallback)
    //
    // These attributes are NOT in the public SDK; they're the same private
    // API VoiceOver uses for web content. AXTextMarker / AXTextMarkerRange are
    // opaque CF types we just pass back as CFTypeRef. Used when AXBoundsForRange
    // is unimplemented (rich contenteditable editors: Gmail, Linear, Notion…).

    /// An opaque text marker addressing character `index` from the element start.
    static func textMarker(forIndex index: Int, in element: AXUIElement) -> CFTypeRef? {
        let number = index as CFNumber
        var result: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, "AXTextMarkerForIndex" as CFString, number, &result)
        return err == .success ? result : nil
    }

    /// A marker range spanning two markers (order-independent).
    static func markerRange(from start: CFTypeRef, to end: CFTypeRef,
                            in element: AXUIElement) -> CFTypeRef? {
        let pair = [start, end] as CFArray
        var result: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, "AXTextMarkerRangeForUnorderedTextMarkers" as CFString, pair, &result)
        return err == .success ? result : nil
    }

    /// Attributed text for a range (AXAttributedStringForRange) — used to read
    /// the font for our own layout when no positional geometry is exposed.
    static func attributedString(forRange range: CFRange, in element: AXUIElement) -> NSAttributedString? {
        var mutableRange = range
        guard let axRange = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXAttributedStringForRange" as CFString, axRange, &result) == .success,
              let result else { return nil }
        return result as? NSAttributedString
    }

    /// The document's start text marker (AXStartTextMarker).
    static func startTextMarker(_ element: AXUIElement) -> CFTypeRef? {
        copy(element, "AXStartTextMarker")
    }

    /// The next text marker after `marker` (AXNextTextMarkerForTextMarker).
    static func nextMarker(after marker: CFTypeRef, in element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXNextTextMarkerForTextMarker" as CFString, marker, &result) == .success,
              let result else { return nil }
        return result
    }

    /// The marker range spanning the visual line that contains `marker`
    /// (AXLineTextMarkerRangeForTextMarker) — the contenteditable line API.
    static func lineMarkerRange(for marker: CFTypeRef, in element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXLineTextMarkerRangeForTextMarker" as CFString, marker, &result) == .success,
              let result else { return nil }
        return result
    }

    /// Screen bounds for a marker range — the contenteditable equivalent of
    /// AXBoundsForRange.
    static func bounds(forMarkerRange range: CFTypeRef, in element: AXUIElement) -> CGRect? {
        var result: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, range, &result)
        guard err == .success, let result,
              CFGetTypeID(result) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        AXValueGetValue(result as! AXValue, .cgRect, &rect)
        return rect.isEmpty ? nil : rect
    }
}

// MARK: - Issues & linter
//
// Stand-in for the NLP/LLM backend: a tiny local rule engine that produces
// real issues to render. Swap this for streamed server suggestions later;
// everything downstream (geometry, squiggles, the card, write-back) is agnostic
// to where the issues come from.

struct Issue {
    let range: NSRange        // UTF-16 range into the field's value
    let replacement: String
    let message: String
    let color: NSColor
}

enum Linter {
    static let misspellings: [String: String] = [
        "teh": "the", "recieve": "receive", "dont": "don't", "wont": "won't",
        "cant": "can't", "alot": "a lot", "definately": "definitely",
        "occured": "occurred", "seperate": "separate", "thier": "their",
        "wich": "which", "becuase": "because", "wierd": "weird", "freind": "friend",
        "adress": "address", "tommorow": "tomorrow", "untill": "until",
    ]

    static func issues(in text: String) -> [Issue] {
        guard !text.isEmpty else { return [] }
        var result: [Issue] = []

        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: .byWords) { sub, range, _, _ in
            guard let sub, let fix = misspellings[sub.lowercased()] else { return }
            let cased = matchCase(fix, like: sub)
            result.append(Issue(range: NSRange(range, in: text),
                                replacement: cased,
                                message: "“\(sub)” → “\(cased)”",
                                color: .systemRed))
        }
        return result
    }

    /// Preserve a leading capital from the original word.
    private static func matchCase(_ replacement: String, like original: String) -> String {
        guard let first = original.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
}

// MARK: - Browser JS bridge (exact caret from the real page)
//
// Runs JavaScript in the browser's active tab via AppleScript and reads the real
// DOM caret rect (getSelection().getClientRects()), relative to the focused
// element — so we map it onto the AX field frame regardless of scroll. Requires
// the browser's "Allow JavaScript from Apple Events" (View → Developer) and
// Automation permission. No extension needed.

/// Result of the in-page caret query: the caret rect (relative to the focused
/// element) and whether the caret's line has no text.
struct CaretInfo {
    let rect: CGRect?
    let lineEmpty: Bool
}

final class BrowserJSBridge {
    static let appNames: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.brave.Browser": "Brave Browser",
        "com.brave.Browser.beta": "Brave Browser Beta",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    // Reads the real DOM caret rect (relative to the focused element) AND whether
    // the caret's block line is empty. No double-quotes/backslashes so it embeds
    // cleanly in the AppleScript string.
    private static let js = "(function(){try{var s=window.getSelection();if(!s||!s.rangeCount){return '';}var r=s.getRangeAt(0);var n=r.startContainer;var blk=(n.nodeType===3)?n.parentNode:n;while(blk&&blk!==document.body){var d=window.getComputedStyle(blk).display;if(d==='block'||d==='list-item'){break;}blk=blk.parentNode;}var empty=blk?((blk.innerText||'').trim().length===0):false;var rect=null;var rs=r.getClientRects();if(rs.length){rect=rs[0];}if(!rect){var o=r.startOffset;var r2=document.createRange();if(n.nodeType===3&&o>0){r2.setStart(n,o-1);r2.setEnd(n,o);var q=r2.getClientRects();if(q.length){rect=q[q.length-1];}}if(!rect&&n.nodeType===3&&n.length>o){r2.setStart(n,o);r2.setEnd(n,o+1);var q2=r2.getClientRects();if(q2.length){rect=q2[0];}}}var el=document.activeElement;var e=el?el.getBoundingClientRect():{left:0,top:0};var out={empty:empty};if(rect){out.x=Math.round(rect.left-e.left);out.y=Math.round(rect.top-e.top);out.h=Math.round(rect.height)||18;}return JSON.stringify(out);}catch(x){return '';}})();"

    private var scripts: [String: NSAppleScript] = [:]   // compiled once per app
    private var warned = false

    /// Caret info from the active tab for a browser app name. Synchronous — call
    /// on the main thread. Reuses a compiled NSAppleScript (no spawn/recompile).
    func caretInfo(appName: String) -> CaretInfo? {
        let script: NSAppleScript
        if let cached = scripts[appName] {
            script = cached
        } else {
            let source = "tell application \"\(appName)\"\nexecute active tab of front window javascript \"\(Self.js)\"\nend tell"
            guard let compiled = NSAppleScript(source: source) else { return nil }
            scripts[appName] = compiled
            script = compiled
        }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            warnOnce(error)
            return nil
        }
        guard let text = descriptor.stringValue, !text.isEmpty,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let lineEmpty = (obj["empty"] as? NSNumber)?.boolValue ?? false
        var rect: CGRect?
        if let x = (obj["x"] as? NSNumber)?.doubleValue,
           let y = (obj["y"] as? NSNumber)?.doubleValue,
           let h = (obj["h"] as? NSNumber)?.doubleValue {
            rect = CGRect(x: x, y: y, width: 2, height: h)
        }
        return CaretInfo(rect: rect, lineEmpty: lineEmpty)
    }

    private func warnOnce(_ error: NSDictionary) {
        guard !warned else { return }
        warned = true
        print("""
        ⚠️ Browser JS caret unavailable. To enable exact in-browser tracking:
           1. In Brave/Chrome: View → Developer → Allow JavaScript from Apple Events
           2. Grant Automation permission for loco to control the browser when prompted
           (\(error[NSAppleScript.errorMessage] ?? error))
        """)
    }
}

// MARK: - Overlay window

/// A borderless, transparent, click-through window pinned above everything.
/// It never participates in hit-testing, so the app underneath behaves normally.
final class OverlayWindow: NSWindow {
    init(screenFrame: NSRect) {
        super.init(contentRect: screenFrame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar                       // above normal windows
        ignoresMouseEvents = true                // clicks pass straight through
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }
}

/// One squiggle to draw: a rect (in view coords) and its color.
struct Underline {
    let rect: CGRect
    let color: NSColor
}

/// Draws wavy squiggles beneath flagged ranges. Coordinates handed in are
/// already converted to this view's (bottom-left origin) space.
final class OverlayView: NSView {
    private var underlines: [Underline] = []
    private var fieldBox: CGRect?   // debug: shows the overlay is rendering

    func update(underlines: [Underline], fieldBox: CGRect?) {
        self.underlines = underlines
        self.fieldBox = fieldBox
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        for underline in underlines {
            underline.color.setStroke()
            let path = squigglePath(under: underline.rect)
            path.stroke()
        }
    }

    /// A small zig-zag wave hugging the bottom edge of `rect`.
    private func squigglePath(under rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineJoinStyle = .round

        let amplitude: CGFloat = 1.8
        let step: CGFloat = 2.0
        let baseline = rect.minY - 1

        var x = rect.minX
        var up = true
        path.move(to: NSPoint(x: x, y: baseline))
        while x < rect.maxX {
            x = min(x + step, rect.maxX)
            path.line(to: NSPoint(x: x, y: baseline + (up ? amplitude : 0)))
            up.toggle()
        }
        return path
    }
}

// MARK: - Floating UI (badge + hover popover)

/// A view that reports mouse enter/exit — used to drive hover state for both
/// the badge and the popover so the popover stays open while the cursor is over
/// either one.
class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// A small, subtle pill shown in the field's left margin. Hovering it opens the
/// suggestions panel. The hover area is the whole view; only the thin pill on
/// its right edge is painted, so it sits just left of the text without overlap.
final class GutterView: HoverView {
    static let size = NSSize(width: 14, height: 22)
    private static let pillWidth: CGFloat = 5

    var count: Int = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: bounds.maxX - Self.pillWidth - 2, y: 2,
                          width: Self.pillWidth, height: bounds.height - 4)
        let color = count > 0 ? NSColor.systemRed : NSColor.systemGray
        color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: Self.pillWidth / 2, yRadius: Self.pillWidth / 2).fill()
    }
}

/// Non-activating panel base — floats above everything and never steals focus
/// from the underlying text field, so write-back keeps working.
class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar          // match the squiggle overlay's level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        // NSPanel defaults this to true, which hides it whenever our (accessory,
        // never-frontmost) app isn't active — i.e. always. Keep it visible.
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts the hoverable count chip pinned to the field's corner.
final class GutterPanel: FloatingPanel {
    let gutter = GutterView(frame: NSRect(origin: .zero, size: GutterView.size))
    init() {
        super.init(size: GutterView.size)
        hasShadow = false
        gutter.autoresizingMask = [.width, .height]
        contentView = gutter
    }
}

/// The bigger "real UI" panel revealed on hover: a header and a list of every
/// issue, each individually fixable, plus Fix-all.
final class PopoverPanel: FloatingPanel, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var webView: WKWebView!

    /// Which corner of the panel is pinned to `anchor`, so it grows away from
    /// the gutter as the web content resizes.
    enum Corner { case bottomRight, topLeft }
    private var anchor: NSPoint = .zero
    private var anchorCorner: Corner = .topLeft

    /// Inbound messages from the React app: {type, ...}.
    var onMessage: (([String: Any]) -> Void)?
    /// Hover state so the popover stays open while the cursor is over it.
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    init(url: URL) {
        super.init(size: NSSize(width: 344, height: 160))
        hasShadow = true   // native shadow (outside the frame, non-interactive)

        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "loco")
        config.userContentController = userContent

        let web = HoverWebView(frame: NSRect(x: 0, y: 0, width: 344, height: 160),
                               configuration: config)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")   // transparent webview
        web.onEnter = { [weak self] in self?.onEnter?() }
        web.onExit = { [weak self] in self?.onExit?() }
        web.load(URLRequest(url: url))

        webView = web
        contentView = web
    }

    /// Push the current issues into the React app.
    func setIssues(_ issues: [Issue]) {
        let payload = issues.map { ["message": $0.message, "replacement": $0.replacement] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.loco && window.loco.setIssues(\(json))")
    }

    func present(anchor: NSPoint, corner: Corner) {
        self.anchor = anchor
        self.anchorCorner = corner
        reposition()
        orderFrontRegardless()
    }

    /// Size to the web content, re-pin to the anchor, and refresh the shadow to
    /// match the new (rounded) content shape.
    func resize(toContentWidth width: CGFloat, height: CGFloat) {
        setContentSize(NSSize(width: width, height: height))
        reposition()
        invalidateShadow()
    }

    private func reposition() {
        let origin: NSPoint
        switch anchorCorner {
        case .bottomRight:
            origin = NSPoint(x: anchor.x - frame.width, y: anchor.y)
        case .topLeft:
            origin = NSPoint(x: anchor.x, y: anchor.y - frame.height)
        }
        setFrameOrigin(origin)
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { onMessage?(body) }
    }
}

/// WKWebView that reports hover enter/exit (WKWebView doesn't subclass HoverView,
/// so it re-implements the tracking area).
final class HoverWebView: WKWebView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

// MARK: - Controller

@MainActor
final class AppController: NSObject {
    private var window: OverlayWindow!
    private var view: OverlayView!
    private var gutterPanel: GutterPanel!
    private var popoverPanel: PopoverPanel!
    private let browserJS = BrowserJSBridge()
    private var timer: Timer?

    // The field + issues the UI currently targets, so Fix can write back.
    private var activeElement: AXUIElement?
    private var activeIssues: [Issue] = []

    // Where the popover's top-left corner is pinned (beside the gutter bar),
    // and a small grace timer so moving gutter→popover doesn't dismiss it.
    private var popoverAnchor: NSPoint = .zero
    private var hideHoverTimer: Timer?

    // Cache so we only re-evaluate when the text/frame changes.
    private var lastSignature: String = ""

    // PIDs we've already force-enabled accessibility on (Chromium/Electron
    // build their AX tree lazily and only for an attached AT — we have to ask).
    private var a11yEnabledPids = Set<pid_t>()

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",   // Arc
        "com.operasoftware.Opera",
        "org.mozilla.firefox",
        "com.apple.Safari",
        // Electron apps benefit from the same switch:
        "com.microsoft.VSCode",
        "com.tinyspeck.slackmacgap",
        "notion.id",
    ]

    func start() {
        if !ensureAccessibilityPermission() {
            // Permission dialog has been shown; the binary now appears in
            // System Settings. User flips the toggle and re-runs.
            print("""
            ⏳ Accessibility permission required.
               1. Open System Settings → Privacy & Security → Accessibility
               2. Enable the entry for this binary (or your terminal app)
               3. Re-run:  swift run loco
            """)
            // Keep running so the toggle can take effect live on some setups.
        }

        let screen = NSScreen.screens.first ?? NSScreen.main!
        window = OverlayWindow(screenFrame: screen.frame)
        view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        window.orderFrontRegardless()

        gutterPanel = GutterPanel()
        gutterPanel.gutter.onEnter = { [weak self] in self?.showPopover() }
        gutterPanel.gutter.onExit = { [weak self] in self?.scheduleHidePopover() }

        popoverPanel = PopoverPanel(url: Self.webURL())
        popoverPanel.onEnter = { [weak self] in self?.cancelHidePopover() }
        popoverPanel.onExit = { [weak self] in self?.scheduleHidePopover() }
        popoverPanel.onMessage = { [weak self] body in self?.handleWebMessage(body) }

        print("✅ loco running. Type a misspelling (e.g. \"teh\", \"recieve\", \"definately\").")
        print("   Red squiggle marks it; hover the badge to open the React panel and Fix.")
        print("   Panel UI from: \(Self.webURL().absoluteString)\n")

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private var dumpedCaps = Set<String>()

    /// One-time dump of a field's AX capabilities + probe of each geometry API,
    /// so we can see which one actually returns a real rect on this field.
    private func dumpCapabilities(_ element: AXUIElement, role: String, value: String) {
        guard !value.isEmpty else { return }
        let attrs = AX.attributeNames(element).sorted()
        let params = AX.parameterizedAttributeNames(element).sorted()
        let key = role + "|" + params.joined(separator: ",")
        guard !dumpedCaps.contains(key) else { return }
        dumpedCaps.insert(key)

        // Probe range [0,3] with each geometry API.
        let probe = CFRange(location: 0, length: min(3, (value as NSString).length))
        let boundsForRange = AX.bounds(of: probe, in: element)
        var markerBounds: CGRect?
        if let s = AX.textMarker(forIndex: 0, in: element),
           let e = AX.textMarker(forIndex: probe.length, in: element),
           let mr = AX.markerRange(from: s, to: e, in: element) {
            markerBounds = AX.bounds(forMarkerRange: mr, in: element)
        }

        print("🔎 \(role)")
        print("   attrs:  \(attrs)")
        print("   params: \(params)")
        print("   probe BoundsForRange=\(boundsForRange.map(NSStringFromRect) ?? "nil") markerBounds=\(markerBounds.map(NSStringFromRect) ?? "nil")")
    }

    private func ensureAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// One sampling pass: find focus, read text + geometry, redraw.
    private func tick() {
        guard let element = AX.focusedElement() else {
            clearIfNeeded()
            return
        }

        // Chromium/Electron won't expose web text until we flip on their AX tree.
        enableBrowserAccessibilityIfNeeded(for: element)

        let role = AX.string(element, kAXRoleAttribute) ?? "?"
        let value = AX.string(element, kAXValueAttribute) ?? ""
        guard let axFrame = AX.frame(element) else {
            clearIfNeeded()
            return
        }

        // Caret/selection drives where the pill sits, so it's part of the
        // change-signature (moving the caret must reposition even if text is same).
        let selection = AX.selectedRange(element)
        let selKey = selection.map { "\($0.location),\($0.length)" } ?? "-"

        // Skip re-evaluation when nothing changed (text, field moved/scrolled, caret).
        let signature = "\(role)|\(NSStringFromRect(axFrame))|\(value.count)|\(value.hashValue)|\(selKey)"
        if signature == lastSignature { return }
        lastSignature = signature

        let fieldBox = toCocoa(axFrame)

        // Detect issues, then resolve each one's on-screen geometry.
        let issues = Linter.issues(in: value)
        var underlines: [Underline] = []
        var firstIssueRect: CGRect?

        for issue in issues {
            guard let rect = screenRect(for: issue.range, in: element),
                  isSaneRect(rect, in: fieldBox) else { continue }
            underlines.append(Underline(rect: rect, color: issue.color))
            if firstIssueRect == nil { firstIssueRect = rect }
        }

        view.update(underlines: underlines, fieldBox: fieldBox)

        // Only show the pill for editable text fields.
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        guard textRoles.contains(role) else {
            dismissUI()
            return
        }

        // Resolve the caret. In browsers, run JS in the real page for the exact
        // DOM caret + line emptiness (handles contenteditable + scroll).
        var caret: CGRect?
        if let appName = browserAppName(for: element), let info = browserJS.caretInfo(appName: appName) {
            if info.lineEmpty { hidePill(); return }   // nothing to flag on a blank line
            if let local = info.rect {
                let rect = CGRect(x: fieldBox.minX + local.minX,
                                  y: fieldBox.maxY - local.minY - local.height,
                                  width: local.width, height: local.height)
                if isInsideField(rect, fieldBox) { caret = rect }
            }
        } else {
            // Non-browser / JS unavailable: use AX, and the value-based empty check.
            if let caretIndex = selection?.location, isCurrentLineEmpty(value: value, caret: caretIndex) {
                hidePill(); return
            }
            caret = resolveCaret(for: element, fieldBox: fieldBox)
        }

        activeElement = element
        activeIssues = issues
        gutterPanel.gutter.count = issues.count   // colour updates immediately
        placeGutter(lineRect: caret ?? firstLineRect(fieldBox), fieldBox: fieldBox)
    }

    private func hidePill() {
        gutterPanel.orderOut(nil)
        popoverPanel.orderOut(nil)
    }

    /// Browser app name (for AppleScript) if the focused element belongs to one.
    private func browserAppName(for element: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier else { return nil }
        return BrowserJSBridge.appNames[bundleID]
    }

    /// Caret rect via the CursorBounds package (text-caret source only, so it
    /// returns nil rather than falling back to the field frame).
    private func resolveCaret(for element: AXUIElement, fieldBox: CGRect) -> CGRect? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        guard let result = try? CursorBounds().cursorPosition(
            forPID: pid, correctionMode: .none, corner: .topLeft, sourcePriority: [.textCaret]
        ) else { return nil }
        let rect = toCocoa(result.bounds)
        return isInsideField(rect, fieldBox) ? rect : nil
    }

    /// Position the pill in the field's left margin at the given line rect.
    private func placeGutter(lineRect: CGRect, fieldBox: CGRect) {
        let chip = GutterView.size
        let gx = fieldBox.minX - chip.width - 4
        let gy = lineRect.midY - chip.height / 2
        gutterPanel.setFrame(NSRect(x: gx, y: gy, width: chip.width, height: chip.height), display: true)
        gutterPanel.orderFrontRegardless()
        popoverAnchor = NSPoint(x: fieldBox.minX, y: gy)
        if popoverPanel.isVisible { showPopover() }
    }

    /// Fallback line rect (first line) when no caret geometry is available.
    private func firstLineRect(_ fieldBox: CGRect) -> CGRect {
        let centerY = fieldBox.maxY - min(16, fieldBox.height / 2)
        return CGRect(x: fieldBox.minX, y: centerY - 8, width: 0, height: 16)
    }

    /// The field's font as a CSS `font` shorthand for the web measurer.
    private func cssFont(_ element: AXUIElement) -> String {
        let font = caretFont(element)
        let family = font.familyName ?? "sans-serif"
        return "\(font.pointSize)px \"\(family)\""
    }

    // MARK: Hover → popover

    private func showPopover() {
        cancelHidePopover()
        guard !activeIssues.isEmpty else { return }
        popoverPanel.setIssues(activeIssues)
        popoverPanel.present(anchor: popoverAnchor, corner: .topLeft)
    }

    /// Where the React panel UI is served from. Override with LOCO_WEB_URL
    /// (e.g. a built dist file:// URL) for a production-style run.
    private static func webURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["LOCO_WEB_URL"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://localhost:5173")!
    }

    private func scheduleHidePopover() {
        hideHoverTimer?.invalidate()
        hideHoverTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.popoverPanel.orderOut(nil) }
        }
    }

    private func cancelHidePopover() {
        hideHoverTimer?.invalidate()
        hideHoverTimer = nil
    }

    // MARK: Messages from the React panel

    private func handleWebMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            // Page finished loading — push whatever issues are current.
            popoverPanel.setIssues(activeIssues)
        case "resize":
            if let width = (body["width"] as? NSNumber)?.doubleValue,
               let height = (body["height"] as? NSNumber)?.doubleValue {
                popoverPanel.resize(toContentWidth: CGFloat(width), height: CGFloat(height))
            }
        case "fix":
            if let index = (body["index"] as? NSNumber)?.intValue,
               activeIssues.indices.contains(index) {
                apply(activeIssues[index])
                finishFix()
            }
        case "fixAll":
            // Apply last→first so earlier ranges stay valid as lengths change.
            for issue in activeIssues.sorted(by: { $0.range.location > $1.range.location }) {
                apply(issue)
            }
            finishFix()
        default:
            break
        }
    }

    /// Replace one issue's range in the field via AX, preserving the rest.
    private func apply(_ issue: Issue) {
        guard let element = activeElement else { return }
        var range = CFRange(location: issue.range.location, length: issue.range.length)
        if let axRange = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
            AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                         issue.replacement as CFString)
        }
    }

    private func finishFix() {
        popoverPanel.orderOut(nil)
        lastSignature = ""   // force a fresh evaluation on the next tick
    }

    private func dismissUI() {
        activeElement = nil
        activeIssues = []
        cancelHidePopover()
        gutterPanel.orderOut(nil)
        popoverPanel.orderOut(nil)
    }

    /// Force a Chromium/Electron app to build and expose its accessibility tree.
    /// Setting `AXManualAccessibility` (and the legacy `AXEnhancedUserInterface`)
    /// on the app element is the documented switch ATs use. Done once per PID.
    private func enableBrowserAccessibilityIfNeeded(for element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              !a11yEnabledPids.contains(pid),
              let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier,
              Self.browserBundleIDs.contains(bundleID)
        else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        a11yEnabledPids.insert(pid)
        print("🌐 enabled AX tree for \(bundleID) (pid \(pid)) — refocus the field")
    }

    private func clearIfNeeded() {
        if lastSignature.isEmpty { return }
        lastSignature = ""
        view.update(underlines: [], fieldBox: nil)
        dismissUI()
    }

    /// A sane rect for the caret's line (or the selection span), or nil when
    /// there's no usable geometry. Rejects the whole-field rect Chromium returns
    /// for a bare caret so the pill doesn't blow up to the field height.
    private func caretRect(element: AXUIElement, selection: CFRange?, fieldBox: CGRect) -> CGRect? {
        guard let sel = selection else { return nil }
        let maxLineHeight: CGFloat = 80   // a single line won't exceed this

        // 1. Caret/selection glyph bounds via AXBoundsForRange (native, search,
        //    real <textarea>). For a caret, probe the adjacent character.
        let probe = sel.length > 0
            ? NSRange(location: sel.location, length: sel.length)
            : NSRange(location: max(sel.location - 1, 0), length: 1)
        if let rect = screenRect(for: probe, in: element),
           isInsideField(rect, fieldBox),
           sel.length > 0 || rect.height <= maxLineHeight {
            return rect
        }

        // 2. Selection marker range (Chromium). Accept a multi-line selection,
        //    but reject a whole-field rect for a bare caret.
        if let markerRange = AX.selectedTextMarkerRange(element),
           let raw = AX.bounds(forMarkerRange: markerRange, in: element) {
            let rect = toCocoa(raw)
            if isInsideField(rect, fieldBox), sel.length > 0 || rect.height <= maxLineHeight {
                return rect
            }
        }

        // 3. No positional geometry (contenteditable): handled async via the web
        //    measurer in tick(). Nothing sync to return here.
        return nil
    }

    /// The field's text font (AXAttributedStringForRange), or a sensible default.
    private func caretFont(_ element: AXUIElement) -> NSFont {
        if let attr = AX.attributedString(forRange: CFRange(location: 0, length: 1), in: element),
           attr.length > 0,
           let font = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            return font
        }
        return NSFont.systemFont(ofSize: 14)
    }

    /// Whether the line containing the caret has no (non-whitespace) text.
    private func isCurrentLineEmpty(value: String, caret: Int) -> Bool {
        let ns = value as NSString
        let length = ns.length
        let position = max(0, min(caret, length))

        var start = position
        while start > 0, ns.character(at: start - 1) != 10 { start -= 1 }   // 10 == "\n"
        var end = position
        while end < length, ns.character(at: end) != 10 { end += 1 }

        let line = ns.substring(with: NSRange(location: start, length: end - start))
        return line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// When line geometry is unavailable, fall back to the field's top line.
    private func topLineFallback(_ fieldBox: CGRect) -> CGRect {
        CGRect(x: fieldBox.minX, y: fieldBox.maxY - 22, width: fieldBox.width, height: 22)
    }

    /// A resolved line/selection rect is trustworthy only if it sits within the
    /// field (contenteditable sometimes returns valid-looking but off-field rects).
    private func isInsideField(_ rect: CGRect, _ field: CGRect) -> Bool {
        guard rect.height > 0 else { return false }
        let slack: CGFloat = 8
        return rect.minY >= field.minY - slack
            && rect.maxY <= field.maxY + slack
            && rect.minX >= field.minX - slack
            && rect.minX <= field.maxX
    }

    /// A rect safe to draw a squiggle for: inside the field and not absurdly
    /// large (some fields return document- or screen-sized rects).
    private func isSaneRect(_ rect: CGRect, in field: CGRect) -> Bool {
        isInsideField(rect, field)
            && rect.width > 0 && rect.width <= field.width + 8
            && rect.height <= 120
    }

    /// Resolve one character range to a screen rect (view coords) via
    /// AXBoundsForRange. Works on native controls and real <textarea>s; returns
    /// nil on fields that don't implement it (most Chromium contenteditable).
    private func screenRect(for ns: NSRange, in element: AXUIElement) -> CGRect? {
        AX.bounds(of: CFRange(location: ns.location, length: ns.length), in: element).map(toCocoa)
    }

    /// AX gives global coords with a top-left origin; AppKit views use
    /// bottom-left. Flip against the primary screen's height. (Single-screen
    /// PoC — multi-monitor needs per-screen mapping.)
    private func toCocoa(_ axRect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let y = primaryHeight - axRect.origin.y - axRect.size.height
        return CGRect(x: axRect.origin.x, y: y, width: axRect.size.width, height: axRect.size.height)
    }
}
