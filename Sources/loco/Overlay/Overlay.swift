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
/// What the pill communicates about the focused field's grammar state.
enum PillState: Equatable {
    case plain          // no verdict yet (e.g. model not ready)
    case checking       // a grammar check is in flight
    case clean          // checked, nothing flagged
    case issues(Int)    // checked, n flagged spots
}

final class OverlayView: NSView {
    private var highlights: [Highlight] = []
    private var pill: CGRect?
    private var pillState: PillState = .plain
    private lazy var pillGlyph = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                         accessibilityDescription: "Rephrase")
    private lazy var checkGlyph = NSImage(systemSymbolName: "checkmark",
                                          accessibilityDescription: "No issues")

    // Pulse: breathe the pill's opacity only while a check is visibly in
    // flight. A sine gives the ease-in-out feel of breathing — calmer than a
    // spinner for something living at the edge of the user's vision.
    private var pulsePhase: CGFloat = 0
    private var pulseTimer: Timer?

    /// Grammar highlights (separate from the pill so each redraws independently).
    func update(highlights: [Highlight]) {
        self.highlights = highlights
        needsDisplay = true
    }

    /// The rephrase pill (nil hides it) and the field state it reflects.
    func setPill(_ rect: CGRect?, state: PillState = .plain) {
        pill = rect
        pillState = state
        let pulsing = rect != nil && state == .checking
        if pulsing, pulseTimer == nil {
            pulsePhase = 0
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pulsePhase += 0.15   // ~1.4s per breath
                    self.needsDisplay = true
                }
            }
        } else if !pulsing {
            pulseTimer?.invalidate()
            pulseTimer = nil
        }
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

        if let pill {
            // Ambient status: color + glyph reflect the field's grammar state.
            let fill: NSColor = switch pillState {
            case .plain: .systemBlue
            case .checking: .white
            case .clean: NSColor(red: 0.25, green: 0.69, blue: 0.31, alpha: 1)   // diff-ins green
            case .issues: NSColor(red: 0.88, green: 0.65, blue: 0.29, alpha: 1)  // amber
            }
            fill.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.width / 2, yRadius: pill.height / 2).fill()

            switch pillState {
            case .checking:
                // White circle with an inner black dot breathing in and out
                // (sine-eased opacity), plus a hairline so the white disc keeps
                // an edge on light backgrounds.
                NSColor.black.withAlphaComponent(0.15).setStroke()
                let rim = NSBezierPath(ovalIn: pill.insetBy(dx: 0.5, dy: 0.5))
                rim.lineWidth = 1
                rim.stroke()
                let dotAlpha = 0.55 + 0.45 * sin(pulsePhase)
                NSColor.black.withAlphaComponent(max(0.08, dotAlpha)).setFill()
                NSBezierPath(ovalIn: pill.insetBy(dx: 5.5, dy: 5.5)).fill()
            case .issues(let n):
                let text = n > 9 ? "9+" : String(n)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.white,
                ]
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: pill.midX - size.width / 2,
                                      y: pill.midY - size.height / 2),
                          withAttributes: attrs)
            case .clean:
                if let glyph = checkGlyph {
                    let inset = pill.insetBy(dx: 4.5, dy: 4.5)
                    glyph.withSymbolConfiguration(.init(paletteColors: [.white]))?
                        .draw(in: inset, from: .zero, operation: .sourceOver, fraction: 1)
                }
            case .plain:
                if let glyph = pillGlyph {
                    let inset = pill.insetBy(dx: 3.5, dy: 3.5)
                    glyph.withSymbolConfiguration(.init(paletteColors: [.white]))?
                        .draw(in: inset, from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
        }
    }
}
