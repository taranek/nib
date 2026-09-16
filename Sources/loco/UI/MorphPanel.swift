import Cocoa
import WebKit

/// What the pill shows: a spinning loader until the user opens the card, a static
/// ring while the card is open, plain blue when no model is ready.
enum PillState: Equatable {
    case plain
    /// Ready, nothing in flight — the orb holds still. Distinct from `loading`
    /// because an orb animating whenever a field is focused means a canvas
    /// repainting at display refresh for as long as the user is writing.
    case idle
    case loading
    case open
}

/// The unified overlay surface: one full-desktop, transparent, non-activating
/// window that hosts a single WKWebView drawing the selection pill and (later)
/// the cards, so the pill can liquid-morph into the card — impossible across two
/// separate windows.
///
/// Click-through is per-region: the window itself participates in hit-testing
/// (`ignoresMouseEvents = false`), but its content view returns `nil` from
/// `hitTest` everywhere except the pill/card rects, so clicks in the empty
/// desktop fall straight through to the app behind. The pill's hover/click come
/// from a native hit view (reliable for a background app, unlike webview
/// `:hover`); the window only becomes key when a card opens.
@MainActor
final class MorphPanel: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let panel: FloatingPanel
    private let content: MorphContentView
    private let pillHit: PillHitView
    private var webView: WKWebView!
    private var loaded = false
    private var pendingJS: [String] = []

    /// Pill anchor in screen coordinates (nil = no pill). Drives both the native
    /// hit view and the pushed web position.
    private(set) var pillScreenRect: CGRect?
    private var pillVisible = false
    private var pillState: PillState = .idle

    /// Card rect in screen coordinates (nil = no card open). The card morphs out
    /// of the pill, so both are pushed together.
    private(set) var cardScreenRect: CGRect?
    private var cardPayload: [String: Any]?

    var onPillClick: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?

    init(url: URL, desktop: NSRect) {
        // FloatingPanel: non-activating, floats, and crucially overrides
        // canBecomeKey — a plain borderless NSPanel can never become key, which
        // silently kills the card's keyboard shortcuts.
        panel = FloatingPanel(size: desktop.size)
        content = MorphContentView(frame: NSRect(origin: .zero, size: desktop.size))
        pillHit = PillHitView(frame: .zero)
        super.init()

        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Click-through by default. Returning nil from hitTest does NOT pass a
        // click to the window below — only ignoresMouseEvents does — so the
        // controller flips this false (via setInteractive) while the cursor is
        // over the pill/card, and true everywhere else.
        panel.ignoresMouseEvents = true

        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "loco")
        userContent.addUserScript(WKUserScript(
            source: "window.__locoMorph = true;",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = userContent
        if url.isFileURL {
            config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        }

        let web = WKWebView(frame: content.bounds, configuration: config)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        if url.isFileURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: url))
        }
        webView = web
        content.addSubview(web)

        pillHit.onClick = { [weak self] in self?.onPillClick?() }
        pillHit.isHidden = true
        content.addSubview(pillHit)   // above the webview for hit-testing

        content.webView = web
        content.pillHit = pillHit
        panel.contentView = content
        panel.setFrame(desktop, display: false)
        panel.orderFrontRegardless()
    }

    /// The desktop-frame origin the whole surface is pinned to — used to map
    /// screen rects into the web's top-left CSS space.
    var desktopOrigin: NSPoint { panel.frame.origin }
    var desktopSize: NSSize { panel.frame.size }

    /// Flip the whole window between click-through (`false`) and interactive
    /// (`true`). The controller drives this from the global mouse monitor: on
    /// while the cursor is over the pill/card, off everywhere else, so clicks in
    /// the empty desktop reach the app behind.
    func setInteractive(_ on: Bool) {
        if panel.ignoresMouseEvents == on { panel.ignoresMouseEvents = !on }
    }

    /// Keep the surface spanning the whole (possibly multi-display) desktop.
    func fit(to desktop: NSRect) {
        panel.setFrame(desktop, display: true)
        content.frame = NSRect(origin: .zero, size: desktop.size)
        webView.frame = content.bounds
        repositionPillHit()
    }

    // MARK: - Pill

    func showPill(at screenRect: CGRect, state: PillState) {
        pillScreenRect = screenRect
        pillVisible = true
        pillState = state
        content.pillRect = screenRect
        repositionPillHit()
        pillHit.isHidden = false
        push()   // handles ordering the window in/out
    }

    func setPillState(_ state: PillState) {
        guard pillVisible else { return }
        pillState = state
        push()
    }

    func hidePill() {
        pillScreenRect = nil
        pillVisible = false
        content.pillRect = nil
        pillHit.isHidden = true
        push()
    }

    // MARK: - Card

    /// Open (or update) the card at `screenRect`, morphing out of the pill. The
    /// window becomes key so the card gets keyboard shortcuts and webview hover.
    func showCard(_ payload: [String: Any], at screenRect: CGRect) {
        cardPayload = payload
        cardScreenRect = screenRect
        content.cardRect = screenRect
        push()   // orders the window in
        panel.makeKey()
        panel.makeFirstResponder(webView)
    }

    /// Move/resize the open card (e.g. after the web reports its real height).
    /// No-op when unchanged — a push here re-renders the web surface, and the
    /// report→reposition→push cycle must converge, not echo.
    func updateCardRect(_ screenRect: CGRect) {
        guard cardPayload != nil, screenRect != cardScreenRect else { return }
        cardScreenRect = screenRect
        content.cardRect = screenRect
        push()
    }

    /// A 1pt offscreen panel used purely to take key status away from the big
    /// panel. Cycling the desktop-sized panel (orderOut/orderFront) reattaches
    /// its whole WKWebView layer tree — profiled at 500-600ms of frozen frames,
    /// which was the laggy close. Bouncing key through this sink costs nothing.
    private lazy var keySink: FloatingPanel = {
        let sink = FloatingPanel(size: NSSize(width: 1, height: 1))
        sink.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        sink.hasShadow = false
        return sink
    }()

    /// Give keystrokes back to the field without touching the big panel's
    /// layer tree: the sink becomes key (big panel resigns), then hides (sink
    /// resigns) — leaving no key window of ours, so the system routes keys to
    /// the frontmost app again.
    private func resignKeyKeepingVisible() {
        guard panel.isKeyWindow else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        keySink.makeKeyAndOrderFront(nil)
        keySink.orderOut(nil)
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if ms > 4 { Log.debug(.perf, "key resign", ["ms": ms]) }
    }

    func hideCard() {
        let t0 = CFAbsoluteTimeGetCurrent()
        cardPayload = nil
        cardScreenRect = nil
        content.cardRect = nil
        push()
        let t1 = CFAbsoluteTimeGetCurrent()
        resignKeyKeepingVisible()
        let t2 = CFAbsoluteTimeGetCurrent()
        if (t2 - t0) > 0.008 {
            Log.debug(.perf, "hideCard breakdown", [
                "pushMs": Int((t1 - t0) * 1000),
                "resignMs": Int((t2 - t1) * 1000),
            ])
        }
    }

    /// Place the native hit view over the pill in window-local (bottom-left)
    /// coordinates: screen rect minus the desktop origin.
    private func repositionPillHit() {
        guard let r = pillScreenRect else { return }
        let o = panel.frame.origin
        pillHit.frame = CGRect(x: r.minX - o.x, y: r.minY - o.y,
                               width: r.width, height: r.height).insetBy(dx: -4, dy: -4)
    }

    /// Screen rect → the web's top-left CSS space (flip Y against the desktop).
    private func cssRect(_ r: CGRect) -> String {
        let o = panel.frame.origin
        let top = (o.y + panel.frame.height) - r.maxY
        return "{x:\(r.minX - o.x),y:\(top),w:\(r.width),h:\(r.height)}"
    }

    /// The last state actually sent — pushes are skipped when nothing changed,
    /// because every push re-renders the surface (detection ticks call showPill
    /// 4x/sec with identical state; re-rendering a desktop-sized webview for
    /// that is pure CPU burn).
    private var lastPush: String?

    /// Push the whole overlay state (pill + card) in one message, so the pill
    /// hiding and the card appearing never land as two frames.
    private func push() {
        let name = switch pillState {
        case .plain: "plain"; case .idle: "idle"; case .loading: "loading"; case .open: "open"
        }
        let pillRectJSON = (pillVisible && pillScreenRect != nil)
            ? cssRect(pillScreenRect!) : "null"
        var cardJSON = "{data:null,rect:null}"
        if let payload = cardPayload, let r = cardScreenRect,
           let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            cardJSON = "{data:\(json),rect:\(cssRect(r))}"
        }
        let js = """
        window.loco && window.loco.setMorph && window.loco.setMorph({\
        pill:{visible:\(pillVisible),state:"\(name)",rect:\(pillRectJSON)},\
        card:\(cardJSON)})
        """
        guard js != lastPush else { return }
        lastPush = js
        Log.debug(.ui, "morph push", [
            "pill": pillVisible ? (pillScreenRect.map(NSStringFromRect) ?? "nil") : "hidden",
            "card": cardScreenRect.map(NSStringFromRect) ?? "nil",
        ])
        eval(js)
        updateWindowVisibility()
    }

    /// The window stays ordered front for the app's whole life, like the
    /// squiggle overlay: an empty static transparent layer costs nothing, while
    /// ordering a desktop-sized WKWebView in or out detaches/reattaches its
    /// whole layer tree — profiled at 300-600ms of frozen frames, which landed
    /// mid-animation as the "laggy close" (and a hitchy first open).
    private func updateWindowVisibility() {
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func eval(_ js: String) {
        guard loaded else { pendingJS.append(js); return }
        // A slow completion means the WebContent process was busy when the push
        // arrived — the eval queues behind whatever it was doing.
        let t0 = CFAbsoluteTimeGetCurrent()
        webView.evaluateJavaScript(js) { _, _ in
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            if ms > 16 {
                Task { @MainActor in
                    Log.debug(.perf, "morph eval slow", ["ms": Int(ms)])
                }
            }
        }
    }

    // MARK: - WK delegates

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let queued = pendingJS
        pendingJS.removeAll()
        queued.forEach { webView.evaluateJavaScript($0) }
    }

    /// Dev diagnosis: compare where the pill actually rendered (DOM rect) with
    /// the CSS rect Swift pushed, plus the webview's viewport vs the panel size.
    /// Logged, so a mismatch pinpoints whether an offset is native or web-side.
    func auditGeometry() {
        let js = """
        (() => { const el = document.querySelector('[data-morph-blob]');
          const r = el ? el.getBoundingClientRect() : null;
          return JSON.stringify({dom: r ? {x: r.x, y: r.y, w: r.width, h: r.height} : null,
            innerW: window.innerWidth, innerH: window.innerHeight}); })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            MainActor.assumeIsolated {
                Log.info(.ui, "morph geometry audit", [
                    "web": (result as? String) ?? "error: \(error.map(String.init(describing:)) ?? "?")",
                    "panel": NSStringFromRect(self.panel.frame),
                    "pillScreen": self.pillScreenRect.map(NSStringFromRect) ?? "nil",
                    "pillCSS": self.pillScreenRect.map { self.cssRect($0) } ?? "nil",
                ])
            }
        }
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { onMessage?(body) }
    }
}

/// Content view that gates click-through: outside the pill/card rects it returns
/// `nil`, so the event falls through to whatever app is behind the transparent
/// desktop window; inside them it routes to the pill hit view or the webview.
private final class MorphContentView: NSView {
    var pillRect: CGRect?   // screen coords
    var cardRect: CGRect?   // screen coords
    weak var webView: NSView?
    weak var pillHit: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in window base (bottom-left) coordinates; map to screen.
        guard let win = window else { return nil }
        let screen = win.convertPoint(toScreen: point)
        if let p = pillRect, p.insetBy(dx: -4, dy: -4).contains(screen) {
            return pillHit ?? super.hitTest(point)
        }
        if let c = cardRect, c.contains(screen) {
            return webView?.hitTest(convert(point, from: nil)) ?? webView
        }
        return nil   // click-through everywhere else
    }
}

/// Transparent native hit target over the pill. Only the click is handled
/// locally (it must be consumed so it doesn't fall through to the field behind);
/// hover enter/exit is driven by the controller's global mouse monitor, since
/// this window is click-through except in the instant the cursor is over the
/// pill, which is too narrow a window for tracking-area enter/exit to be
/// reliable.
private final class PillHitView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}
