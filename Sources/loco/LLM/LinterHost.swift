import Cocoa
import WebKit

/// One Harper lint: a UTF-16 span into the checked text, a human-readable
/// message, and replacement suggestions (may be empty).
struct HarperLint {
    let range: NSRange
    let message: String
    let suggestions: [String]
}

/// Hosts the rule-based Harper linter (harper.js WASM) in an offscreen
/// webview — the instant, deterministic first pass for English grammar
/// checking. Swift calls lint(); spans come back in UTF-16 units, which map
/// 1:1 onto NSRange.
@MainActor
final class LinterHost: NSObject, WKScriptMessageHandler {
    private var webView: WKWebView!
    private(set) var ready = false
    private var nextID = 0
    private var pending: [Int: ([HarperLint]) -> Void] = [:]

    init(url: URL) {
        super.init()
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "loco")
        userContent.addUserScript(WKUserScript(
            source: "window.__locoLinter = true;",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = userContent
        if url.isFileURL {
            config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        }
        // Offscreen: never added to a window; evaluateJavaScript still works.
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1),
                            configuration: config)
        if url.isFileURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: url))
        }
        webView = web
    }

    /// Lint `text`; completion delivers lints on the main actor. Completes with
    /// [] if the linter isn't ready (callers fall back to the LLM path).
    func lint(_ text: String, completion: @escaping ([HarperLint]) -> Void) {
        guard ready,
              let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else {
            completion([])
            return
        }
        nextID += 1
        let id = nextID
        pending[id] = completion
        webView.evaluateJavaScript(
            "window.loco && window.loco.lint && window.loco.lint((\(json))[0], \(id))")
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "linterReady":
            ready = true
            print("⚡ harper linter ready")
        case "lints":
            guard let id = (body["id"] as? NSNumber)?.intValue,
                  let completion = pending.removeValue(forKey: id) else { return }
            let raw = body["lints"] as? [[String: Any]] ?? []
            let lints = raw.compactMap { l -> HarperLint? in
                guard let start = (l["start"] as? NSNumber)?.intValue,
                      let end = (l["end"] as? NSNumber)?.intValue,
                      end > start else { return nil }
                return HarperLint(
                    range: NSRange(location: start, length: end - start),
                    message: l["message"] as? String ?? "",
                    suggestions: l["suggestions"] as? [String] ?? [])
            }
            completion(lints)
        default:
            break
        }
    }
}
