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

    // Spinner: rotate the arc only while a check is visibly in flight.
    private var spinPhase: CGFloat = 0
    private var spinTimer: Timer?

    /// Grammar highlights (separate from the pill so each redraws independently).
    func update(highlights: [Highlight]) {
        self.highlights = highlights
        needsDisplay = true
    }

    /// The rephrase pill (nil hides it) and the field state it reflects.
    func setPill(_ rect: CGRect?, state: PillState = .plain) {
        pill = rect
        pillState = state
        let spinning = rect != nil && state == .checking
        if spinning, spinTimer == nil {
            spinTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.spinPhase += 0.22
                    self.needsDisplay = true
                }
            }
        } else if !spinning {
            spinTimer?.invalidate()
            spinTimer = nil
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
            case .plain, .checking: .systemBlue
            case .clean: NSColor(red: 0.25, green: 0.69, blue: 0.31, alpha: 1)   // diff-ins green
            case .issues: NSColor(red: 0.88, green: 0.65, blue: 0.29, alpha: 1)  // amber
            }
            fill.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.width / 2, yRadius: pill.height / 2).fill()

            switch pillState {
            case .checking:
                // Rotating 270° arc.
                let arc = NSBezierPath()
                let center = NSPoint(x: pill.midX, y: pill.midY)
                let start = spinPhase * 180 / .pi
                arc.appendArc(withCenter: center, radius: pill.width / 2 - 4,
                              startAngle: start, endAngle: start + 270)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                NSColor.white.setStroke()
                arc.stroke()
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
