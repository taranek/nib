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

// MARK: - Issues & linter
//
// Stand-in for the NLP/LLM backend: a tiny local rule engine that produces
// real issues to render. Swap this for streamed server suggestions later;
// everything downstream (geometry, highlights, the card, write-back) is agnostic
// to where the issues come from.

enum Linter {
    static let misspellings: [String: String] = [
        "teh": "the", "recieve": "receive", "dont": "don't", "wont": "won't",
        "cant": "can't", "alot": "a lot", "definately": "definitely",
        "occured": "occurred", "seperate": "separate", "thier": "their",
        "wich": "which", "becuase": "because", "wierd": "weird", "freind": "friend",
        "adress": "address", "tommorow": "tomorrow", "untill": "until",
    ]

    /// Native-field lint: scan the raw text value for known misspellings.
    static func words(in text: String) -> [(word: String, replacement: String, range: NSRange)] {
        guard !text.isEmpty else { return [] }
        var result: [(String, String, NSRange)] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: .byWords) { sub, range, _, _ in
            guard let sub, let fix = misspellings[sub.lowercased()] else { return }
            let cased = matchCase(fix, like: sub)
            result.append((String(sub), cased, NSRange(range, in: text)))
        }
        return result
    }

    /// Preserve a leading capital from the original word.
    static func matchCase(_ replacement: String, like original: String) -> String {
        guard let first = original.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
}

/// One flagged word with everything the overlay + card + write-back need.
struct FlaggedWord {
    let word: String
    let replacement: String
    let message: String
    let category: String
    let rect: CGRect          // Cocoa coords (bottom-left origin), screen space
    let range: NSRange?       // native write-back via AX (nil for browsers)
    let key: String           // lowercased word
    let occurrence: Int       // Nth match of this key — disambiguates duplicates

    /// Stable identity for hover/dismiss bookkeeping.
    var id: String { "\(key)#\(occurrence)" }
}

// MARK: - Browser bridge (in-page DOM scan + write-back)
//
// Contenteditable surfaces (Gmail, docs, chat boxes) expose text via AX but no
// per-range geometry — so we run JS in the real page to FIND the misspellings
// and read each word's DOM rect directly. Same channel applies fixes. Requires
// the browser's "Allow JavaScript from Apple Events" (View → Developer) and
// Automation permission. No extension needed.

/// A flagged word as the page reports it: text, fix, and a rect relative to the
/// focused element's bounding box.
struct RawHit {
    let word: String
    let replacement: String
    let key: String
    let occurrence: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

final class BrowserBridge {
    static let appNames: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.brave.Browser": "Brave Browser",
        "com.brave.Browser.beta": "Brave Browser Beta",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    /// The misspelling table as a JS object literal. Keys are lowercase letters
    /// (valid identifiers); values use backticks so apostrophes ("don't") need no
    /// escaping — and no double-quotes/backslashes, so it embeds in AppleScript.
    private static let dictLiteral: String = {
        let entries = Linter.misspellings.map { "\($0.key):`\($0.value)`" }
        return "{" + entries.joined(separator: ",") + "}"
    }()

    // Walk the focused contenteditable's text nodes, flag dictionary words, and
    // return each match's DOM rect relative to the element. Skips non-editable
    // focus (URL bar, page body) so we never highlight the whole page.
    private static let scanJS = "(function(){try{var el=document.activeElement;if(!el||!el.isContentEditable){return '';}var dict=" + dictLiteral + ";var e=el.getBoundingClientRect();var wk=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,null);var out=[];var re=/[A-Za-z]+/g;var nd;var occ={};while(nd=wk.nextNode()){var t=nd.nodeValue;re.lastIndex=0;var m;while(m=re.exec(t)){var w=m[0];var k=w.toLowerCase();var rp=dict[k];if(rp){var ix=(occ[k]||0);occ[k]=ix+1;var rg=document.createRange();rg.setStart(nd,m.index);rg.setEnd(nd,m.index+w.length);var rc=rg.getBoundingClientRect();if(rc.width>0){out.push({w:w,r:rp,k:k,i:ix,x:Math.round(rc.left-e.left),y:Math.round(rc.top-e.top),width:Math.round(rc.width),h:Math.round(rc.height)});}}}}return JSON.stringify(out);}catch(x){return '';}})();"

    private var scanScripts: [String: NSAppleScript] = [:]   // compiled once per app
    private var warned = false

    /// Flagged words from the active tab's focused contenteditable. Synchronous —
    /// call on the main thread. Returns nil when JS is unavailable / not editable.
    func scan(appName: String) -> [RawHit]? {
        let script: NSAppleScript
        if let cached = scanScripts[appName] {
            script = cached
        } else {
            guard let compiled = NSAppleScript(source: wrap(appName, Self.scanJS)) else { return nil }
            scanScripts[appName] = compiled
            script = compiled
        }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error { warnOnce(error); return nil }
        guard let text = descriptor.stringValue, !text.isEmpty,
              let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        return arr.compactMap { obj in
            guard let w = obj["w"] as? String, let r = obj["r"] as? String,
                  let k = obj["k"] as? String,
                  let i = (obj["i"] as? NSNumber)?.intValue,
                  let x = (obj["x"] as? NSNumber)?.doubleValue,
                  let y = (obj["y"] as? NSNumber)?.doubleValue,
                  let width = (obj["width"] as? NSNumber)?.doubleValue,
                  let h = (obj["h"] as? NSNumber)?.doubleValue else { return nil }
            return RawHit(word: w, replacement: r, key: k, occurrence: i,
                          x: x, y: y, width: width, height: h)
        }
    }

    /// Replace the Nth occurrence of `key` in the focused contenteditable with
    /// `replacement`, via the DOM (execCommand so the editor's model updates).
    func replace(appName: String, key: String, occurrence: Int, replacement: String) {
        let js = "(function(){try{var el=document.activeElement;if(!el||!el.isContentEditable){return 'no';}var key=`\(key)`;var target=\(occurrence);var rep=`\(replacement)`;var wk=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,null);var re=/[A-Za-z]+/g;var nd;var occ=0;while(nd=wk.nextNode()){var t=nd.nodeValue;re.lastIndex=0;var m;while(m=re.exec(t)){var w=m[0];if(w.toLowerCase()===key){if(occ===target){var rg=document.createRange();rg.setStart(nd,m.index);rg.setEnd(nd,m.index+w.length);var sel=window.getSelection();sel.removeAllRanges();sel.addRange(rg);if(!document.execCommand('insertText',false,rep)){nd.nodeValue=t.slice(0,m.index)+rep+t.slice(m.index+w.length);}return 'ok';}occ++;}}}return 'miss';}catch(x){return 'err';}})();"
        var error: NSDictionary?
        NSAppleScript(source: wrap(appName, js))?.executeAndReturnError(&error)
        if let error { warnOnce(error) }
    }

    private func wrap(_ appName: String, _ js: String) -> String {
        "tell application \"\(appName)\"\nexecute active tab of front window javascript \"\(js)\"\nend tell"
    }

    private func warnOnce(_ error: NSDictionary) {
        guard !warned else { return }
        warned = true
        print("""
        ⚠️ Browser JS unavailable. To enable in-browser highlighting:
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

/// One word highlight: a rect (view coords) and its accent color.
struct Highlight {
    let rect: CGRect
    let color: NSColor
}

/// Draws a soft colored highlight under each flagged word, plus a thin accent
/// line at the baseline — the Grammarly inline look. Coordinates handed in are
/// already converted to this view's (bottom-left origin) space.
final class OverlayView: NSView {
    private var highlights: [Highlight] = []

    func update(highlights: [Highlight]) {
        self.highlights = highlights
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        for h in highlights {
            let box = h.rect.insetBy(dx: -1, dy: -1)
            h.color.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()

            // Accent underline hugging the baseline.
            h.color.withAlphaComponent(0.9).setStroke()
            let line = NSBezierPath()
            line.lineWidth = 2
            line.move(to: NSPoint(x: box.minX + 1, y: box.minY + 0.5))
            line.line(to: NSPoint(x: box.maxX - 1, y: box.minY + 0.5))
            line.stroke()
        }
    }
}

// MARK: - Floating popover

/// A view that reports mouse enter/exit — keeps the popover open while the cursor
/// is over it.
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

/// Non-activating panel base — floats above everything and never steals focus
/// from the underlying text field, so write-back keeps working.
class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar          // match the overlay's level
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

/// The per-word suggestion card: category, the suggestion (click to apply),
/// Dismiss, and a footer link. Anchored just under the flagged word.
final class PopoverPanel: FloatingPanel, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var webView: WKWebView!

    /// Top-left of the card is pinned to `anchor`; it grows downward.
    private var anchor: NSPoint = .zero

    var onMessage: (([String: Any]) -> Void)?
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    init(url: URL) {
        super.init(size: NSSize(width: 300, height: 150))
        hasShadow = true   // native shadow (outside the frame, non-interactive)

        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "loco")
        config.userContentController = userContent

        let web = HoverWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 150),
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

    /// Push the current single suggestion into the React card.
    func setSuggestion(_ word: FlaggedWord) {
        let payload: [String: Any] = [
            "message": word.message,
            "suggestion": word.replacement,
            "category": word.category,
            "word": word.word,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.loco && window.loco.setSuggestion(\(json))")
    }

    func present(anchor: NSPoint) {
        self.anchor = anchor
        reposition()
        orderFrontRegardless()
    }

    func resize(toContentWidth width: CGFloat, height: CGFloat) {
        setContentSize(NSSize(width: width, height: height))
        reposition()
        invalidateShadow()
    }

    private func reposition() {
        setFrameOrigin(NSPoint(x: anchor.x, y: anchor.y - frame.height))
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { onMessage?(body) }
    }
}

// MARK: - Controller

@MainActor
final class AppController: NSObject {
    private var window: OverlayWindow!
    private var view: OverlayView!
    private var popoverPanel: PopoverPanel!
    private let browser = BrowserBridge()
    private var timer: Timer?
    private var mouseMonitor: Any?

    // The field + flagged words the UI currently targets.
    private var activeElement: AXUIElement?
    private var activeBrowserAppName: String?
    private var flagged: [FlaggedWord] = []

    // The word whose card is open, and the word the cursor is currently over.
    private var activeWord: FlaggedWord?
    private var hoveredID: String?
    private var hideHoverTimer: Timer?

    // Words the user dismissed (by id) — cleared whenever the text changes,
    // since edits shift occurrence indices.
    private var dismissed = Set<String>()

    // Cache so we only re-evaluate when text/frame/selection changes.
    private var lastSignature: String = ""
    private var lastValueHash: Int = 0

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
            print("""
            ⏳ Accessibility permission required.
               1. Open System Settings → Privacy & Security → Accessibility
               2. Enable the entry for this binary (or your terminal app)
               3. Re-run:  swift run loco
            """)
        }

        let screen = NSScreen.screens.first ?? NSScreen.main!
        window = OverlayWindow(screenFrame: screen.frame)
        view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        window.orderFrontRegardless()

        popoverPanel = PopoverPanel(url: Self.webURL())
        popoverPanel.onEnter = { [weak self] in self?.cancelHidePopover() }
        popoverPanel.onExit = { [weak self] in self?.scheduleHidePopover() }
        popoverPanel.onMessage = { [weak self] body in self?.handleWebMessage(body) }

        print("✅ loco running. Type a misspelling (e.g. \"teh\", \"recieve\", \"definately\").")
        print("   The word gets highlighted; hover it to open the card and apply the fix.")
        print("   Card UI from: \(Self.webURL().absoluteString)\n")

        // Hover detection over the click-through overlay: a global mouse monitor
        // (fires for other apps; our accessory app is never frontmost) checks the
        // cursor against the flagged-word rects without consuming the events.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseMove() }
        }

        // Event-driven: react to focus/value/selection changes via AXObserver,
        // and to app switches via NSWorkspace. A slow safety poll backstops
        // anything not delivered as a notification (e.g. scroll, window moves).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        rebuildObservers()

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - AX observers (event-driven updates)

    private var axObserver: AXObserver?
    private var observedElement: AXUIElement?

    @objc private func activeAppChanged() {
        rebuildObservers()
        tick()
    }

    /// (Re)create the AXObserver for the frontmost app and observe focus changes.
    private func rebuildObservers() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        observedElement = nil

        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }

        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let controller = Unmanaged<AppController>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { controller.handleAXNotification(notification as String) }
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        axObserver = observer

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, appElement,
                                  kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        attachToFocusedElement()
    }

    /// Observe value/selection changes on the currently focused element.
    private func attachToFocusedElement() {
        guard let observer = axObserver else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let old = observedElement {
            AXObserverRemoveNotification(observer, old, kAXValueChangedNotification as CFString)
            AXObserverRemoveNotification(observer, old, kAXSelectedTextChangedNotification as CFString)
        }
        observedElement = AX.focusedElement()
        if let element = observedElement {
            AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
            AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, refcon)
        }
    }

    private func handleAXNotification(_ notification: String) {
        if notification == kAXFocusedUIElementChangedNotification as String {
            attachToFocusedElement()
        }
        tick()
    }

    private func ensureAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// One pass: find focus, detect flagged words + geometry, redraw highlights.
    private func tick() {
        guard let element = AX.focusedElement() else {
            clearIfNeeded()
            return
        }

        // Keep value/selection observers attached to the live focused element.
        if observedElement == nil || !CFEqual(observedElement!, element) {
            attachToFocusedElement()
        }

        // Chromium/Electron won't expose web text until we flip on their AX tree.
        enableBrowserAccessibilityIfNeeded(for: element)

        let role = AX.string(element, kAXRoleAttribute) ?? "?"
        let value = AX.string(element, kAXValueAttribute) ?? ""
        guard let axFrame = AX.frame(element) else {
            clearIfNeeded()
            return
        }

        // Caret/selection + frame are part of the change-signature so scroll and
        // caret moves re-evaluate (highlight rects move even if text is same).
        let selection = AX.selectedRange(element)
        let selKey = selection.map { "\($0.location),\($0.length)" } ?? "-"
        let signature = "\(role)|\(NSStringFromRect(axFrame))|\(value.hashValue)|\(selKey)"
        if signature == lastSignature { return }
        lastSignature = signature

        // Text changed → drop stale dismissals (occurrence indices shift).
        if value.hashValue != lastValueHash {
            dismissed.removeAll()
            lastValueHash = value.hashValue
        }

        let fieldBox = toCocoa(axFrame)
        let appName = browserAppName(for: element)

        // Detect flagged words. Browser contenteditable → in-page DOM scan;
        // everything else → AX value lint + AXBoundsForRange geometry.
        var words: [FlaggedWord] = []
        if let appName, let hits = browser.scan(appName: appName) {
            activeBrowserAppName = appName
            for h in hits {
                let rect = CGRect(x: fieldBox.minX + h.x,
                                  y: fieldBox.maxY - h.y - h.height,
                                  width: h.width, height: h.height)
                guard isInsideField(rect, fieldBox) else { continue }
                words.append(FlaggedWord(word: h.word, replacement: h.replacement,
                                         message: message(h.word, h.replacement),
                                         category: "Correctness", rect: rect, range: nil,
                                         key: h.key, occurrence: h.occurrence))
            }
        } else {
            activeBrowserAppName = nil
            let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
            if textRoles.contains(role) {
                var occ: [String: Int] = [:]
                for hit in Linter.words(in: value) {
                    let key = hit.word.lowercased()
                    let i = occ[key, default: 0]; occ[key] = i + 1
                    guard let rect = screenRect(for: hit.range, in: element),
                          isSaneRect(rect, in: fieldBox) else { continue }
                    words.append(FlaggedWord(word: hit.word, replacement: hit.replacement,
                                             message: message(hit.word, hit.replacement),
                                             category: "Correctness", rect: rect, range: hit.range,
                                             key: key, occurrence: i))
                }
            }
        }

        words = words.filter { !dismissed.contains($0.id) }

        activeElement = element
        flagged = words
        view.update(highlights: words.map { Highlight(rect: $0.rect, color: .systemRed) })

        // If the open card's word is gone (fixed/edited away), close it.
        if let aw = activeWord, !words.contains(where: { $0.id == aw.id }) {
            popoverPanel.orderOut(nil)
            activeWord = nil
            hoveredID = nil
        }
    }

    private func message(_ word: String, _ replacement: String) -> String {
        "“\(word)” → “\(replacement)”"
    }

    /// Browser app name (for AppleScript) if the focused element belongs to one.
    private func browserAppName(for element: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier else { return nil }
        return BrowserBridge.appNames[bundleID]
    }

    // MARK: Hover → card

    /// Driven by the global mouse monitor: open the card for the word under the
    /// cursor, keep it open over the word or the card, hide otherwise.
    private func handleMouseMove() {
        let p = NSEvent.mouseLocation

        if popoverPanel.isVisible, popoverPanel.frame.insetBy(dx: -4, dy: -4).contains(p) {
            cancelHidePopover()
            return
        }

        if let hit = flagged.first(where: { $0.rect.insetBy(dx: -2, dy: -3).contains(p) }) {
            cancelHidePopover()
            if hit.id != hoveredID {
                hoveredID = hit.id
                showCard(for: hit)
            }
        } else if hoveredID != nil {
            hoveredID = nil
            scheduleHidePopover()
        }
    }

    private func showCard(for word: FlaggedWord) {
        activeWord = word
        popoverPanel.setSuggestion(word)
        // Anchor the card's top-left just below the word, growing downward.
        popoverPanel.present(anchor: NSPoint(x: word.rect.minX, y: word.rect.minY - 6))
    }

    /// Where the React card UI is served from. Override with LOCO_WEB_URL
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
            MainActor.assumeIsolated {
                self?.popoverPanel.orderOut(nil)
                self?.activeWord = nil
                self?.hoveredID = nil
            }
        }
    }

    private func cancelHidePopover() {
        hideHoverTimer?.invalidate()
        hideHoverTimer = nil
    }

    // MARK: Messages from the React card

    private func handleWebMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            if let word = activeWord { popoverPanel.setSuggestion(word) }
        case "resize":
            if let width = (body["width"] as? NSNumber)?.doubleValue,
               let height = (body["height"] as? NSNumber)?.doubleValue {
                popoverPanel.resize(toContentWidth: CGFloat(width), height: CGFloat(height))
            }
        case "apply":
            if let word = activeWord { apply(word) }
            finishCard()
        case "dismiss":
            if let word = activeWord { dismissed.insert(word.id) }
            finishCard()
        default:
            break
        }
    }

    /// Apply one fix: browser → DOM replace via JS; native → AX range replace.
    private func apply(_ word: FlaggedWord) {
        if let appName = activeBrowserAppName {
            browser.replace(appName: appName, key: word.key,
                            occurrence: word.occurrence, replacement: word.replacement)
        } else if let element = activeElement, let range = word.range {
            var cf = CFRange(location: range.location, length: range.length)
            if let axRange = AXValueCreate(.cfRange, &cf) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
                AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                             word.replacement as CFString)
            }
        }
    }

    private func finishCard() {
        popoverPanel.orderOut(nil)
        activeWord = nil
        hoveredID = nil
        lastSignature = ""   // force a fresh evaluation on the next tick
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
        flagged = []
        view.update(highlights: [])
        popoverPanel.orderOut(nil)
        activeWord = nil
        hoveredID = nil
        activeElement = nil
    }

    /// A resolved rect is trustworthy only if it sits within the field
    /// (contenteditable sometimes returns valid-looking but off-field rects).
    private func isInsideField(_ rect: CGRect, _ field: CGRect) -> Bool {
        guard rect.height > 0 else { return false }
        let slack: CGFloat = 8
        return rect.minY >= field.minY - slack
            && rect.maxY <= field.maxY + slack
            && rect.minX >= field.minX - slack
            && rect.minX <= field.maxX
    }

    /// A rect safe to draw a highlight for: inside the field and not absurdly
    /// large (some fields return document- or screen-sized rects).
    private func isSaneRect(_ rect: CGRect, in field: CGRect) -> Bool {
        isInsideField(rect, field)
            && rect.width > 0 && rect.width <= field.width + 8
            && rect.height <= 120
    }

    /// Resolve one character range to a screen rect (view coords) via
    /// AXBoundsForRange. Works on native controls and real <textarea>s; returns
    /// nil on fields that don't implement it.
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
