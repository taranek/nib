import Cocoa
import ApplicationServices
import WebKit

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

    var count: Int = 0 { didSet { needsDisplay = true } }   // kept for the panel

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: bounds.maxX - Self.pillWidth - 2, y: 2,
                          width: Self.pillWidth, height: bounds.height - 4)
        NSColor.systemRed.setFill()
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

        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
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
            guard let rect = screenRect(for: issue.range, in: element) else { continue }
            underlines.append(Underline(rect: rect, color: issue.color))
            if firstIssueRect == nil { firstIssueRect = rect }
        }

        view.update(underlines: underlines, fieldBox: fieldBox)

        if issues.isEmpty {
            dismissUI()
        } else {
            activeElement = element
            activeIssues = issues

            // Decide the line to mark, best geometry first:
            //   1. caret line / selection span (native fields, textareas)
            //   2. the first issue's line (when caret isn't exposed but ranges are)
            //   3. the field's top line (nothing resolves)
            // The pill always sits in the left margin; only its Y/height vary.
            let caretRect = caretLineRect(element: element, selection: selection)
                .flatMap { isInsideField($0, fieldBox) ? $0 : nil }
            let anchorRect = caretRect ?? firstIssueRect ?? topLineFallback(fieldBox)

            let chipW = GutterView.size.width
            let gx = fieldBox.minX - chipW - 4         // left margin
            let gh = max(anchorRect.height, 16)
            let gutterFrame = NSRect(x: gx, y: anchorRect.minY, width: chipW, height: gh)
            gutterPanel.gutter.count = issues.count
            gutterPanel.setFrame(gutterFrame, display: true)
            gutterPanel.orderFrontRegardless()

            // Drop the popover from the field's left, just below the marked line.
            popoverAnchor = NSPoint(x: fieldBox.minX, y: anchorRect.minY - 4)

            // If the popover is already open (user mid-interaction), refresh it.
            if popoverPanel.isVisible { showPopover() }
        }

        let geom = firstIssueRect == nil ? "none" : "ok"
        let caretOK = caretLineRect(element: element, selection: selection)
            .map { isInsideField($0, fieldBox) } == true
        let track = issues.isEmpty ? "-" : (caretOK ? "caret" : (firstIssueRect != nil ? "issue" : "fallback"))
        print("focus[\(role)] issues:\(issues.count) drawn:\(underlines.count) geom:\(geom) track:\(track)")
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

    /// Rect of the focused line, or the whole selection if text is selected.
    private func caretLineRect(element: AXUIElement, selection: CFRange?) -> CGRect? {
        guard let sel = selection else { return nil }

        // A real selection → bounding rect spanning it (across lines).
        if sel.length > 0 {
            return screenRect(for: NSRange(location: sel.location, length: sel.length), in: element)
        }

        // Just a caret → resolve the current line's range, then its bounds.
        if let line = AX.lineNumber(forCharIndex: sel.location, in: element),
           let lineRange = AX.range(forLine: line, in: element),
           let rect = screenRect(for: NSRange(location: lineRange.location,
                                              length: max(lineRange.length, 1)), in: element) {
            return rect
        }

        // contenteditable line API: caret marker → its line's marker range → bounds.
        if let marker = AX.textMarker(forIndex: sel.location, in: element),
           let lineMarkerRange = AX.lineMarkerRange(for: marker, in: element),
           let rect = AX.bounds(forMarkerRange: lineMarkerRange, in: element) {
            return toCocoa(rect)
        }

        // Last resort: the caret glyph's own rect (correct line y, thin height).
        return screenRect(for: NSRange(location: sel.location, length: 1), in: element)
            ?? screenRect(for: NSRange(location: max(sel.location - 1, 0), length: 1), in: element)
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

    /// Resolve one character range to a screen rect (view coords). Tries
    /// AXBoundsForRange first (native controls, web textareas), then the text
    /// marker path (contenteditable).
    private func screenRect(for ns: NSRange, in element: AXUIElement) -> CGRect? {
        if let r = AX.bounds(of: CFRange(location: ns.location, length: ns.length), in: element) {
            return toCocoa(r)
        }
        if let start = AX.textMarker(forIndex: ns.location, in: element),
           let end = AX.textMarker(forIndex: ns.location + ns.length, in: element),
           let mr = AX.markerRange(from: start, to: end, in: element),
           let r = AX.bounds(forMarkerRange: mr, in: element) {
            return toCocoa(r)
        }
        return nil
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
