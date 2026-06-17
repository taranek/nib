import Cocoa

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

/// One word highlight: a rect (view coords) and its accent color.
struct Highlight {
    let rect: CGRect
    let color: NSColor
}

/// Draws a soft colored highlight under each flagged word, plus a thin accent
/// line at the baseline — the Grammarly inline look. Coordinates handed in are
/// already converted to this view's (bottom-left origin) space.
final class OverlayView: NSView {
    private var highlights: [Highlight] = []

    func update(highlights: [Highlight]) {
        self.highlights = highlights
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        for h in highlights {
            let box = h.rect.insetBy(dx: -1, dy: -1)
            h.color.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()

            // Accent underline hugging the baseline.
            h.color.withAlphaComponent(0.9).setStroke()
            let line = NSBezierPath()
            line.lineWidth = 2
            line.move(to: NSPoint(x: box.minX + 1, y: box.minY + 0.5))
            line.line(to: NSPoint(x: box.maxX - 1, y: box.minY + 0.5))
            line.stroke()
        }
    }
}
