import Cocoa
import WebKit

/// What the pill shows: a spinning loader until the user opens the card,
/// a static ring while the card is open, plain blue when no model is ready.
enum PillState: Equatable {
    case plain
    case loading
    case open
}

/// Transparent hit-target layered over the pill webview: tracking areas fire
/// regardless of key/active status (unlike webview :hover for a background
/// app), so hover and click stay reliable while the user works elsewhere.
private final class PillTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClick: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The selection pill as a tiny web surface: a WKWebView renders the visuals
/// (CSS handles state transitions + the checking pulse, off the main thread);
/// native tracking supplies hover/click. Swift pushes state via setPill().
@MainActor
final class PillPanel: NSObject, WKNavigationDelegate {
    /// Window edge; the 18px pill is centered inside.
    static let size: CGFloat = 26

    private let panel: FloatingPanel
    private var webView: WKWebView!
    private var loaded = false
    private var pending: (visible: Bool, state: PillState)?

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClick: (() -> Void)?

    init(url: URL) {
        panel = FloatingPanel(size: NSSize(width: Self.size, height: Self.size))
        super.init()
        panel.hasShadow = false

        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.addUserScript(WKUserScript(
            source: "window.__locoPill = true;",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = userContent
        if url.isFileURL {
            config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        let web = WKWebView(frame: container.bounds, configuration: config)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        if url.isFileURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: url))
        }
        webView = web
        container.addSubview(web)

        let tracker = PillTrackingView(frame: container.bounds)
        tracker.autoresizingMask = [.width, .height]
        tracker.onEnter = { [weak self] in self?.onEnter?() }
        tracker.onExit = { [weak self] in self?.onExit?() }
        tracker.onClick = { [weak self] in self?.onClick?() }
        container.addSubview(tracker)

        panel.contentView = container
    }

    /// Show the pill centered on `rect` (screen coords) with the given state.
    func show(at rect: CGRect, state: PillState) {
        panel.setFrameOrigin(NSPoint(x: rect.midX - Self.size / 2,
                                     y: rect.midY - Self.size / 2))
        push(state: state)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func setState(_ state: PillState) {
        guard panel.isVisible else { return }
        push(state: state)
    }

    private func push(state: PillState) {
        guard loaded else { pending = (true, state); return }
        let name = switch state {
        case .plain: "plain"
        case .loading: "loading"
        case .open: "open"
        }
        webView.evaluateJavaScript(
            "window.loco && window.loco.setPill && window.loco.setPill({state:\"\(name)\"})")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let pending {
            self.pending = nil
            push(state: pending.state)
        }
    }
}
