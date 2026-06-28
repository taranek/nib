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

    func show(relativeTo button: NSStatusBarButton) {
        if let win = button.window {
            anchor = win.convertToScreen(button.convert(button.bounds, to: nil))
        }
        reposition()
        // Accessory (background) app: orderFrontRegardless shows the panel without
        // activating the app; makeKey then routes keyboard/input to it.
        panel.orderFrontRegardless()
        panel.makeKey()
        installClickMonitor()
    }

    func close() {
        removeClickMonitor()
        panel.orderOut(nil)
    }

    /// Size the panel to the web content (card + transparent margin) and reposition.
    func resize(toContentWidth width: CGFloat, height: CGFloat) {
        panel.setContentSize(NSSize(width: width, height: height))
        reposition()
    }

    private func reposition() {
        let size = panel.frame.size
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
                  model: String, targetLanguage: String) {
        let payload: [String: Any] = [
            "enabled": enabled,
            "accessibilityTrusted": accessibilityTrusted,
            "llmStatus": llmStatus,
            "model": model,
            "targetLanguage": targetLanguage,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.loco && window.loco.setSettings && window.loco.setSettings(\(json))")
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { onMessage?(body) }
    }
}
