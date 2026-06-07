import Cocoa
import ApplicationServices

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
        return rect
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

/// Draws the focused-field outline and per-word underlines. Coordinates handed
/// in are already converted to this view's (bottom-left origin) space.
final class OverlayView: NSView {
    var fieldBox: CGRect?
    var underlines: [CGRect] = []

    func update(fieldBox: CGRect?, underlines: [CGRect]) {
        self.fieldBox = fieldBox
        self.underlines = underlines
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        if let box = fieldBox {
            NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
            let path = NSBezierPath(rect: box)
            path.lineWidth = 1.5
            path.stroke()
        }

        NSColor.systemRed.setFill()
        for rect in underlines {
            // 2pt bar along the bottom edge of each word — a stand-in for the
            // real squiggle a suggestion engine would draw.
            let bar = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2)
            NSBezierPath(rect: bar).fill()
        }
    }
}

// MARK: - Controller

@MainActor
final class AppController: NSObject {
    private var window: OverlayWindow!
    private var view: OverlayView!
    private var timer: Timer?

    // Cache so we only re-measure word geometry when the text/frame changes.
    private var lastSignature: String = ""

    func start() {
        if !ensureAccessibilityPermission() {
            // Permission dialog has been shown; the binary now appears in
            // System Settings. User flips the toggle and re-runs.
            print("""
            ⏳ Accessibility permission required.
               1. Open System Settings → Privacy & Security → Accessibility
               2. Enable the entry for this binary (or your terminal app)
               3. Re-run:  swift run loco
            """)
            // Keep running so the toggle can take effect live on some setups.
        }

        let screen = NSScreen.screens.first ?? NSScreen.main!
        window = OverlayWindow(screenFrame: screen.frame)
        view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        window.orderFrontRegardless()

        print("✅ loco running. Click into any text field — focus it and type.")
        print("   Blue box = focused element.  Red bars = per-word geometry.\n")

        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func ensureAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// One sampling pass: find focus, read text + geometry, redraw.
    private func tick() {
        guard let element = AX.focusedElement() else {
            clearIfNeeded()
            return
        }

        let role = AX.string(element, kAXRoleAttribute) ?? "?"
        let value = AX.string(element, kAXValueAttribute) ?? ""
        guard let axFrame = AX.frame(element) else {
            clearIfNeeded()
            return
        }

        // Skip the expensive per-word pass when nothing changed.
        let signature = "\(role)|\(NSStringFromRect(axFrame))|\(value.count)|\(value.hashValue)"
        if signature == lastSignature { return }
        lastSignature = signature

        let fieldBox = toCocoa(axFrame)
        let underlines = measureWords(in: value, element: element)

        view.update(fieldBox: fieldBox, underlines: underlines)

        let preview = value.prefix(48).replacingOccurrences(of: "\n", with: "⏎")
        print("focus[\(role)] words:\(underlines.count) value:\"\(preview)\"")
    }

    private func clearIfNeeded() {
        if lastSignature.isEmpty { return }
        lastSignature = ""
        view.update(fieldBox: nil, underlines: [])
    }

    /// Split the value into words and ask AX for each word's screen rect.
    /// Capped to keep a single pass cheap on huge documents.
    private func measureWords(in value: String, element: AXUIElement) -> [CGRect] {
        guard !value.isEmpty else { return [] }

        var rects: [CGRect] = []
        var measured = 0
        let cap = 120

        value.enumerateSubstrings(in: value.startIndex..<value.endIndex,
                                   options: .byWords) { _, wordRange, _, stop in
            if measured >= cap { stop = true; return }
            let nsRange = NSRange(wordRange, in: value)
            let cfRange = CFRange(location: nsRange.location, length: nsRange.length)
            if let axRect = AX.bounds(of: cfRange, in: element) {
                rects.append(self.toCocoa(axRect))
            }
            measured += 1
        }
        return rects
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
