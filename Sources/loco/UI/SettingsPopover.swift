import Cocoa
import WebKit

/// A transient popover anchored to the menu bar icon, hosting the web UI in
/// settings mode. Actions flow back over the same `loco` message bridge.
@MainActor
final class SettingsPopover: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let popover = NSPopover()
    private(set) var webView: WKWebView!
    var onMessage: (([String: Any]) -> Void)?

    private static let size = NSSize(width: 380, height: 420)

    init(url: URL) {
        super.init()

        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "loco")
        config.userContentController = userContent
        if url.isFileURL {
            config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        }

        let web = WKWebView(frame: NSRect(origin: .zero, size: Self.size), configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")   // show the popover's material
        if url.isFileURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: url))
        }
        webView = web

        let vc = NSViewController()
        vc.view = web
        popover.contentViewController = vc
        popover.contentSize = Self.size
        popover.behavior = .transient   // closes when you click away
        popover.animates = true
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() { popover.close() }

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
