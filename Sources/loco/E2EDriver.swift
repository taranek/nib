import Cocoa
import Network
import ScreenCaptureKit

/// Dev-only end-to-end driver (`LOCO_E2E_PORT=…`): a loopback HTTP control
/// port that lets a test script drive the REAL user flow — synthetic mouse
/// moves/clicks/typing/shortcuts posted as HID events (loco already holds the
/// Accessibility grant, the terminal doesn't) — and observe it: controller
/// state as JSON and screenshots (full-screen regions need the Screen
/// Recording grant; `/snap` of our own overlay surface never does).
///
/// All coordinates are CG global space: top-left origin of the primary display.
///
///   GET /state                          controller + overlay geometry
///   GET /move?x=&y=[&steps=]            glide the pointer (fires hover)
///   GET /click?x=&y=[&count=2]          left click
///   GET /drag?x=&y=&x2=&y2=             press, glide, release (selects text)
///   GET /type?text=                     type unicode text
///   GET /key?code=&mods=cmd,shift,…     one key chord (kVK code)
///   GET /shot?path=[&x=&y=&w=&h=]       screen capture → PNG
///   GET /snap?path=                     our overlay webview only → PNG
///   GET /js?code=                       evaluate JS in the overlay webview
@MainActor
final class E2EDriver {
    private let listener: NWListener
    private let stateProvider: () -> [String: Any]
    private let webSnapshot: (@escaping (NSImage?) -> Void) -> Void
    private let webEval: (String, @escaping (Any?) -> Void) -> Void

    init?(port: UInt16,
          state: @escaping () -> [String: Any],
          snapshot: @escaping (@escaping (NSImage?) -> Void) -> Void,
          eval: @escaping (String, @escaping (Any?) -> Void) -> Void) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        guard let l = try? NWListener(using: params) else { return nil }
        listener = l
        stateProvider = state
        webSnapshot = snapshot
        webEval = eval
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            Self.readRequest(conn) { target in
                MainActor.assumeIsolated {
                    guard let self else { conn.cancel(); return }
                    self.handle(target) { status, body in
                        Self.respond(conn, status: status, body: body)
                    }
                }
            }
        }
        l.start(queue: .main)
        Log.info(.app, "e2e driver listening", ["port": Int(port),
                                                 "screenCapture": CGPreflightScreenCaptureAccess()])
    }

    // MARK: HTTP plumbing (just enough for curl)

    private nonisolated static func readRequest(_ conn: NWConnection, _ done: @escaping (String) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let parts = (text.split(separator: "\r\n").first ?? "").split(separator: " ")
            done(parts.count > 1 ? String(parts[1]) : "/")
        }
    }

    private nonisolated static func respond(_ conn: NWConnection, status: Int, body: Any) {
        let data: Data
        if let s = body as? String { data = Data((s + "\n").utf8) }
        else { data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data() }
        let head = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: Routing

    private func handle(_ target: String, reply: @escaping (Int, Any) -> Void) {
        let comps = URLComponents(string: target)
        var q: [String: String] = [:]
        comps?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        func num(_ k: String) -> CGFloat? { q[k].flatMap(Double.init).map { CGFloat($0) } }
        let path = comps?.path ?? target

        switch path {
        case "/state":
            reply(200, stateProvider())
        case "/move":
            guard let x = num("x"), let y = num("y") else { return reply(400, "x,y required") }
            glide(to: CGPoint(x: x, y: y), steps: Int(num("steps") ?? 12), button: nil) { reply(200, "ok") }
        case "/click":
            guard let x = num("x"), let y = num("y") else { return reply(400, "x,y required") }
            click(at: CGPoint(x: x, y: y), count: Int(num("count") ?? 1))
            reply(200, "ok")
        case "/drag":
            guard let x = num("x"), let y = num("y"), let x2 = num("x2"), let y2 = num("y2") else {
                return reply(400, "x,y,x2,y2 required")
            }
            let from = CGPoint(x: x, y: y), to = CGPoint(x: x2, y: y2)
            post(.mouseMoved, at: from)
            post(.leftMouseDown, at: from)
            glide(to: to, steps: 16, button: .left) {
                self.post(.leftMouseUp, at: to)
                reply(200, "ok")
            }
        case "/type":
            type(q["text"] ?? "") { reply(200, "ok") }
        case "/key":
            guard let code = q["code"].flatMap(UInt16.init) else { return reply(400, "code required") }
            key(code, mods: Self.flags(q["mods"] ?? ""))
            reply(200, "ok")
        case "/shot":
            let out = q["path"] ?? NSTemporaryDirectory() + "loco-shot.png"
            var rect: CGRect?
            if let x = num("x"), let y = num("y"), let w = num("w"), let h = num("h") {
                rect = CGRect(x: x, y: y, width: w, height: h)
            }
            capture(rect: rect, to: out) { err in
                reply(err == nil ? 200 : 500, err ?? out)
            }
        case "/snap":
            let out = q["path"] ?? NSTemporaryDirectory() + "loco-snap.png"
            webSnapshot { image in
                guard let image, Self.writePNG(image, to: out) else { return reply(500, "snapshot failed") }
                reply(200, out)
            }
        case "/js":
            webEval(q["code"] ?? "") { result in reply(200, ["result": result.map { "\($0)" } ?? "null"]) }
        default:
            reply(404, "unknown route \(path)")
        }
    }

    // MARK: Input synthesis

    private let source = CGEventSource(stateID: .hidSystemState)

    private func post(_ type: CGEventType, at p: CGPoint, clickState: Int = 1) {
        let button: CGMouseButton = .left
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e.post(tap: .cghidEventTap)
    }

    /// Move in small steps with a frame between them, like a hand — hover
    /// logic keys off a stream of mouseMoved events, not a teleport.
    private func glide(to end: CGPoint, steps: Int, button: CGMouseButton?, done: @escaping () -> Void) {
        let start = CGEvent(source: nil)?.location ?? end
        let n = max(1, steps)
        var i = 0
        func step() {
            i += 1
            let t = CGFloat(i) / CGFloat(n)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(button == nil ? .mouseMoved : .leftMouseDragged, at: p)
            if i < n {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { step() }
            } else {
                done()
            }
        }
        step()
    }

    private func click(at p: CGPoint, count: Int) {
        post(.mouseMoved, at: p)
        for c in 1...max(1, count) {
            post(.leftMouseDown, at: p, clickState: c)
            post(.leftMouseUp, at: p, clickState: c)
        }
    }

    private func type(_ text: String, done: @escaping () -> Void) {
        let units = Array(text.utf16)
        var i = 0
        func next() {
            guard i < units.count else { return done() }
            // One character per event pair, paced — apps that batch or drop
            // bursts (Electron) see realistic typing.
            var u = [units[i]]
            if UTF16.isLeadSurrogate(units[i]), i + 1 < units.count { u.append(units[i + 1]); i += 1 }
            i += 1
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                e?.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { next() }
        }
        next()
    }

    private func key(_ code: UInt16, mods: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = mods
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func flags(_ s: String) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in s.split(separator: ",") {
            switch m {
            case "cmd": f.insert(.maskCommand)
            case "shift": f.insert(.maskShift)
            case "alt", "opt": f.insert(.maskAlternate)
            case "ctrl": f.insert(.maskControl)
            default: break
            }
        }
        return f
    }

    // MARK: Capture

    private func capture(rect: CGRect?, to path: String, done: @escaping (String?) -> Void) {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()   // shows the system prompt once
            return done("no Screen Recording permission for this binary — grant it in System Settings, then relaunch")
        }
        guard #available(macOS 14.0, *) else { return done("needs macOS 14") }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                // The display containing the rect's origin (or the main one).
                let probe = rect?.origin ?? .zero
                guard let display = content.displays.first(where: { $0.frame.contains(probe) })
                        ?? content.displays.first else { return done("no display") }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                let scale = NSScreen.screens.first { $0.frame.size == display.frame.size }?.backingScaleFactor ?? 2
                if let r = rect {
                    let local = r.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                    config.sourceRect = local
                    config.width = Int(local.width * scale)
                    config.height = Int(local.height * scale)
                } else {
                    config.width = Int(display.frame.width * scale)
                    config.height = Int(display.frame.height * scale)
                }
                config.showsCursor = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let ok = Self.writePNG(NSImage(cgImage: image, size: .zero), to: path)
                done(ok ? nil : "write failed")
            } catch {
                done("capture failed: \(error.localizedDescription)")
            }
        }
    }

    private static func writePNG(_ image: NSImage, to path: String) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return FileManager.default.createFile(atPath: path, contents: png)
    }

    /// Cocoa screen rect (bottom-left origin) → CG global (top-left origin).
    static func cg(_ r: CGRect) -> [String: Double] {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return ["x": r.minX, "y": h - r.maxY, "w": r.width, "h": r.height,
                "cx": r.midX, "cy": h - r.midY]
    }
}
