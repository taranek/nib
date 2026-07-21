import Cocoa
import WebKit

/// The settings UI, shown in a custom borderless panel under the menu-bar icon
/// (no NSPopover arrow). Same chrome as the rewrite card: a rounded card drawn in
/// CSS inside a transparent shadow margin. Keeps the previous public API.
@MainActor
final class SettingsPopover: NSObject, WKScriptMessageHandler, WKNavigationDelegate,
    NSWindowDelegate {
    private let panel: FloatingPanel
    private(set) var webView: WKWebView!
    var onMessage: (([String: Any]) -> Void)?

    /// Transparent margin around the card (matches CSS `.wrap` padding) so the
    /// card's soft CSS shadow has room and the rounded corners aren't framed.
    private let shadowMargin: CGFloat = 24
    private var anchor: NSRect = .zero   // the status-item button, in screen coords
    private var clickMonitor: Any?

    init(url: URL) {
        // Start roughly card-sized; the web layer reports its real size to resize().
        panel = FloatingPanel(size: NSSize(width: 380 + 48, height: 420 + 48))
        super.init()
        panel.hasShadow = false   // the card draws its own soft CSS shadow
        panel.delegate = self

        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "loco")
        // Mark this webview as the settings surface before any page script runs
        // (more reliable than a file:// URL #settings fragment with loadFileURL).
        userContent.addUserScript(WKUserScript(
            source: "window.__locoSettings = true;",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = userContent
        if url.isFileURL {
            config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        }

        let web = WKWebView(frame: NSRect(origin: .zero, size: panel.frame.size),
                            configuration: config)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")   // transparent webview
        if url.isFileURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: url))
        }
        webView = web
        panel.contentView = web
    }

    var isShown: Bool { panel.isVisible }
    /// Showing the centered first-run onboarding (vs the anchored settings).
    var isOnboarding: Bool { centered && panel.isVisible }
    // Onboarding is shown centered on screen and stays put (no click-to-dismiss),
    // so stepping out to System Settings to grant permission doesn't close it.
    private var centered = false
    // Once the user drags the panel, content resizes must not snap it back.
    private var userMoved = false

    /// Anchored under the menu-bar icon (regular settings).
    func show(relativeTo button: NSStatusBarButton) {
        centered = false
        userMoved = false
        if let win = button.window {
            anchor = win.convertToScreen(button.convert(button.bounds, to: nil))
        }
        present(dismissOnOutsideClick: true)
    }

    /// Centered on the active screen (first-run onboarding).
    func showCentered() {
        centered = true
        userMoved = false
        present(dismissOnOutsideClick: false)
    }

    private func present(dismissOnOutsideClick: Bool) {
        // Settings is a focusable surface (unlike the rewrite card, it doesn't need
        // to preserve another app's text focus). An LSUIElement build runs as
        // .accessory and never activates, so its panel stays behind the foreground
        // app even with orderFrontRegardless. Become a regular app while it's open
        // so we can activate and show it on top; revert on close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        reposition()
        panel.makeKeyAndOrderFront(nil)
        if dismissOnOutsideClick { installClickMonitor() }
    }

    func close() {
        removeClickMonitor()
        panel.orderOut(nil)
        // Back to a background (menu-bar-only) app.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Temporarily drop below app-modal windows (e.g. an NSOpenPanel) so the panel
    /// doesn't cover them; pair with restoreLevel().
    func lowerBelowModal() { panel.level = .normal }
    func restoreLevel() { panel.level = .statusBar }

    /// Size the panel to the web content (card + transparent margin) and reposition.
    func resize(toContentWidth width: CGFloat, height: CGFloat) {
        panel.setContentSize(NSSize(width: width, height: height))
        reposition()
    }

    private func reposition() {
        // The user placed it — respect that through content resizes.
        if userMoved { return }
        let size = panel.frame.size

        if centered {
            // Center on the screen with the menu bar (the active one).
            let screen = NSScreen.main ?? NSScreen.screens.first
            guard let vis = screen?.visibleFrame else { return }
            panel.setFrameOrigin(NSPoint(x: vis.midX - size.width / 2,
                                         y: vis.midY - size.height / 2))
            return
        }

        // Center the panel (and thus the card) under the icon, with the card's top
        // just below the menu bar; clamp on-screen.
        var origin = NSPoint(x: anchor.midX - size.width / 2,
                             y: anchor.minY - size.height + shadowMargin - 2)
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY))
        } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            let edge: CGFloat = 8
            origin.x = min(max(origin.x, vis.minX + edge), vis.maxX - edge - size.width)
            origin.y = max(origin.y, vis.minY + edge)
        }
        panel.setFrameOrigin(origin)
    }

    // Close when the user clicks outside the panel — but not on the status item
    // itself (its own click toggles the panel).
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                if self.panel.frame.contains(p) || self.anchor.contains(p) { return }
                self.close()
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Push state into the settings UI.
    func setState(enabled: Bool, accessibilityTrusted: Bool, llmStatus: String,
                  model: String, targetLanguage: String, onboardingCompleted: Bool) {
        let payload: [String: Any] = [
            "enabled": enabled,
            "accessibilityTrusted": accessibilityTrusted,
            "llmStatus": llmStatus,
            "model": model,
            "targetLanguage": targetLanguage,
            "onboardingCompleted": onboardingCompleted,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.loco && window.loco.setSettings && window.loco.setSettings(\(json))")
    }

    // MARK: - Onboarding sandbox (DOM bridge)

    /// Read the sandbox textarea's text and on-screen rect (for anchoring the
    /// card). WebKit won't expose our own webview's text to AX, so we go through
    /// the DOM directly.
    func sandboxField(_ completion: @escaping (String, CGRect) -> Void) {
        let js = """
        (function(){
          var el = document.querySelector('[data-sandbox-input]');
          if(!el) return '';
          var r = el.getBoundingClientRect();
          return JSON.stringify({t: el.value, x: r.left, y: r.top, w: r.width, h: r.height});
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let s = result as? String, !s.isEmpty,
                  let data = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = o["t"] as? String,
                  let x = (o["x"] as? NSNumber)?.doubleValue,
                  let y = (o["y"] as? NSNumber)?.doubleValue,
                  let w = (o["w"] as? NSNumber)?.doubleValue,
                  let h = (o["h"] as? NSNumber)?.doubleValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            // DOM coords are top-left from the webview origin; the borderless panel's
            // content view fills it, so convert to screen (bottom-left) coords.
            let f = self.panel.frame
            let rect = CGRect(x: f.minX + CGFloat(x),
                              y: f.maxY - CGFloat(y) - CGFloat(h),
                              width: CGFloat(w), height: CGFloat(h))
            completion(text, rect)
        }
    }

    /// Start a native window drag from the current mouse event (the webview eats
    /// mouse events, so the DOM top bar reports mousedown and we take over).
    func beginDrag() {
        guard let event = NSApp.currentEvent else { return }
        userMoved = true
        panel.performDrag(with: event)
    }

    /// Re-key the panel and make the web content first responder, so a DOM
    /// autofocus actually takes keyboard focus. Needed after an NSOpenPanel (the
    /// model picker) steals key from the onboarding panel.
    func focusWebContent() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
    }

    /// Convert a rect in webview DOM coords (top-left origin) to screen coords.
    func domRectToScreen(x: Double, y: Double, w: Double, h: Double) -> CGRect {
        let f = panel.frame
        return CGRect(x: f.minX + CGFloat(x), y: f.maxY - CGFloat(y) - CGFloat(h),
                      width: CGFloat(w), height: CGFloat(h))
    }

    /// Push model-download progress into the settings/onboarding UI.
    func setDownload(id: String, progress: Double, error: String? = nil, done: Bool = false) {
        var payload: [String: Any] = ["id": id, "progress": progress, "done": done]
        if let error { payload["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.loco && window.loco.downloadProgress && window.loco.downloadProgress(\(json))")
    }

    /// Tell the sandbox UI a fix was applied (ticks the substep's checkmark).
    func notifySandboxApplied(_ text: String) {
        let arg = (try? JSONSerialization.data(withJSONObject: [text]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        webView.evaluateJavaScript(
            "window.loco && window.loco.sandboxApplied && window.loco.sandboxApplied((\(arg))[0])")
    }

    /// Write text back into the sandbox textarea (uncontrolled DOM) and fire an
    /// `input` event so anything listening stays in sync.
    func setSandboxField(_ text: String) {
        let arg = (try? JSONSerialization.data(withJSONObject: [text]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let js = """
        (function(){
          var el = document.querySelector('[data-sandbox-input]');
          if(!el) return;
          el.value = (\(arg))[0];
          el.dispatchEvent(new Event('input', {bubbles:true}));
        })()
        """
        webView.evaluateJavaScript(js)
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { onMessage?(body) }
    }
}
