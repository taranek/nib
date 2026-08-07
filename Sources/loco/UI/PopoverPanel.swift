import Cocoa
import WebKit

// MARK: - Floating card

/// A WKWebView that reports mouse enter/exit — keeps the card open while the
/// cursor is over it.
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
        // macOS only delivers mouseMoved (which drives CSS :hover in the WKWebView)
        // to the KEY window. A .nonactivatingPanel can be key without activating
        // our app or stealing the browser's focus, so allow it + accept moves.
        acceptsMouseMovedEvents = true
        // NSPanel defaults this to true, which hides it whenever our (accessory,
        // never-frontmost) app isn't active — i.e. always. Keep it visible.
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The per-word suggestion card: category, the suggestion (click to apply),
/// Dismiss, and a footer link. Anchored just under the flagged word.
final class PopoverPanel: FloatingPanel, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var webView: WKWebView!

    /// The rect (screen coords) the card must not cover — the flagged word,
    /// the selection pill, or the sandbox textarea. The card opens below it,
    /// flipping above when there's no room (e.g. Slack's bottom-anchored input).
    private var avoidRect: CGRect = .zero

    var onMessage: (([String: Any]) -> Void)?
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    /// Transparent margin (CSS `.wrap` padding) around the card inside the window,
    /// so the CSS shadow has room and the rounded corners aren't framed by the
    /// rectangular native window shadow. Must match `.wrap { padding }`.
    private let shadowMargin: CGFloat = 24

    init(url: URL) {
        super.init(size: NSSize(width: 300, height: 150))
        // No native (rectangular) shadow — the card draws its own soft, rounded
        // shadow in CSS within the transparent margin.
        hasShadow = false

        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "loco")
        config.userContentController = userContent
        if url.isFileURL {
            // Module scripts + assets under file:// are otherwise blocked by CORS.
            config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        }

        let web = HoverWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 150),
                               configuration: config)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")   // transparent webview
        web.onEnter = { [weak self] in self?.onEnter?() }
        web.onExit = { [weak self] in self?.onExit?() }
        if url.isFileURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: url))
        }

        webView = web
        contentView = web
    }

    /// Push a rephrase/grammar proposal into the card (loading state until the
    /// result
    /// arrives).
    /// Push card data (grammar result or rewrite request) to the React card.
    func setCard(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.loco && window.loco.setCard && window.loco.setCard(\(json))")
    }

    func present(avoiding rect: CGRect) {
        avoidRect = rect
        reposition()
        orderFrontRegardless()
        // Become key (without activating the app, since it's non-activating) so
        // the webview receives mouseMoved (CSS :hover) and key events (shortcuts).
        makeKey()
        makeFirstResponder(webView)
    }

    func resize(toContentWidth width: CGFloat, height: CGFloat) {
        // Size + origin in ONE setFrame: the card is top-anchored, so a height
        // change moves the origin too — applying them as two mutations makes
        // content near the bottom edge (the Accept footer) visibly jitter.
        let size = NSSize(width: width, height: height)
        guard size != frame.size else { return }
        setFrame(NSRect(origin: origin(forSize: size), size: size), display: true)
    }

    private func reposition() {
        setFrameOrigin(origin(forSize: frame.size))
    }

    /// Window origin for a given size: card below `avoidRect` when it fits,
    /// above it otherwise — never covering the text it refers to — clamped
    /// on-screen. (`shadowMargin` is the transparent border around the card.)
    private func origin(forSize size: NSSize) -> NSPoint {
        let nudgeX: CGFloat = 16
        let gap: CGFloat = 4      // breathing room between the card and the rect
        let edge: CGFloat = 8
        // The display holding the thing we're avoiding; when that's unknown
        // (an empty rect), the one under the pointer — never blindly the primary.
        let anchor = avoidRect.isEmpty ? NSEvent.mouseLocation
                                       : NSPoint(x: avoidRect.midX, y: avoidRect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main

        var origin = NSPoint(x: avoidRect.minX - shadowMargin + nudgeX, y: 0)
        // Below: the card's visual top sits just under the rect.
        origin.y = avoidRect.minY - gap - size.height + shadowMargin
        if let vis = screen?.visibleFrame {
            if origin.y < vis.minY + edge {
                // No room below — flip above: visual bottom just over the rect.
                origin.y = avoidRect.maxY + gap - shadowMargin
            }
            origin.x = min(origin.x, vis.maxX - edge - size.width)
            origin.x = max(origin.x, vis.minX + edge)
            origin.y = min(origin.y, vis.maxY - edge - size.height)
            origin.y = max(origin.y, vis.minY + edge)
        }
        return origin
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { onMessage?(body) }
    }
}
