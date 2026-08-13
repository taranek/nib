import Cocoa
import WebKit

/// The wedged-app alert, shown under the menu-bar icon when the app the user is
/// writing in has a stalled accessibility server (Nib is blind there until it
/// restarts). A web surface, so it wears the same dark, rounded identity as the
/// rewrite card — driven by the shared Vite bundle's `#alert` route.
@MainActor
final class WedgeAlert: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let panel: FloatingPanel
    private var webView: WKWebView!
    var onReopen: (() -> Void)?

    /// Transparent margin around the card (matches the web `.w-max p-6`) so its
    /// soft CSS shadow has room; the panel is sized to the reported content.
    private var anchor: NSRect = .zero
    private var pendingAppName: String?
    private var loaded = false
    /// The app currently being alerted about — a repeat show for the same app is
    /// a no-op so it doesn't re-pop on every tick.
    private var shownFor: String?

    init(url: URL) {
        panel = FloatingPanel(size: NSSize(width: 300 + 48, height: 160))
        super.init()
        panel.hasShadow = false   // the card draws its own soft CSS shadow

        let config = WKWebViewConfiguration()
        let content = WKUserContentController()
        content.add(self, name: "loco")
        content.addUserScript(WKUserScript(source: "window.__locoAlert = true;",
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = content
        if url.isFileURL {
            config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        }
        let web = WKWebView(frame: NSRect(origin: .zero, size: panel.frame.size), configuration: config)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        if url.isFileURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: url))
        }
        webView = web
        panel.contentView = web
    }

    func show(appName: String, below button: NSStatusBarButton) {
        if shownFor == appName, panel.isVisible { return }
        shownFor = appName
        if let win = button.window {
            anchor = win.convertToScreen(button.convert(button.bounds, to: nil))
        }
        pendingAppName = appName
        pushAppName()
        reposition()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    /// Forget the memo so the alert can reappear if the app wedges again later.
    func reset() {
        shownFor = nil
        hide()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        pushAppName()
    }

    private func pushAppName() {
        guard loaded, let name = pendingAppName,
              let data = try? JSONSerialization.data(withJSONObject: ["appName": name]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.loco && window.loco.setAlert && window.loco.setAlert(\(json))")
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            pushAppName()
        case "resize":
            if let w = body["width"] as? CGFloat, let h = body["height"] as? CGFloat {
                panel.setContentSize(NSSize(width: w, height: h))
                reposition()
            }
        case "reopenApp":
            reset()
            onReopen?()
        case "dismissAlert":
            hide()   // stays down until the app recovers and wedges again
        default:
            break
        }
    }

    /// Under the status item, right edges aligned, clamped on-screen.
    private func reposition() {
        let size = panel.frame.size
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY))
        } ?? NSScreen.main
        var origin = NSPoint(x: anchor.maxX - size.width + 24, y: anchor.minY - size.height + 24)
        if let vis = screen?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
            origin.y = max(origin.y, vis.minY + 8)
        }
        panel.setFrameOrigin(origin)
    }
}
