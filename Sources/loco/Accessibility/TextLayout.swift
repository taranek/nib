import AppKit
import Foundation

/// Where a word sits on screen, for apps that won't say.
///
/// Electron apps (Slack is the one that matters) expose the text and a frame
/// for the block it lives in, but `AXBoundsForRange` returns an empty rect and
/// the line queries claim the whole message is a single line even when it
/// visibly wraps. There is no per-character geometry to ask for.
///
/// So it is reconstructed: lay the same string out in the same width at the
/// same font size, and read the rects back. It is a model of the app's layout
/// rather than the app's own answer — good to within a few points when the font
/// matches, and wrong if the app uses a font we can't see. Only ever used as a
/// fallback, and only for drawing.
enum TextLayout {
    /// Fonts to try. The app doesn't name its font, so the one whose layout best
    /// reproduces the block's real height is the closest model of it. Slack uses
    /// Lato; other Electron apps mostly use the system face.
    private static let candidates = ["Lato-Regular", "Lato", "Helvetica Neue", "Arial"]

    /// The font whose layout height comes closest to the block's actual height,
    /// which is the only ground truth the app gives us. A wrong font drifts a
    /// little on every line and the error accumulates down the message, so this
    /// is worth the few layout passes — and the answer is cached by the caller.
    static func calibratedFont(text: String, block: CGRect, fontSize: CGFloat) -> NSFont {
        var best = NSFont.systemFont(ofSize: fontSize)
        var bestError = abs(height(of: text, font: best, width: block.width) - block.height)
        for name in candidates {
            guard let font = NSFont(name: name, size: fontSize) else { continue }
            let error = abs(height(of: text, font: font, width: block.width) - block.height)
            if error < bestError { best = font; bestError = error }
        }
        return best
    }

    /// Height the text takes when laid out in this block — exposed so a caller
    /// can log why a layout was rejected.
    static func modelledHeight(text: String, block: CGRect, font: NSFont) -> CGFloat {
        height(of: text, font: font, width: block.width)
    }

    private static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let (layout, container, storage) = engine(text: text, font: font, width: width)
        // The storage owns the layout manager. Let ARC release it here and the
        // whole stack goes with it, and every measurement comes back as zero.
        return withExtendedLifetime(storage) {
            layout.ensureLayout(for: container)
            return layout.usedRect(for: container).height
        }
    }

    private static func engine(text: String, font: NSFont, width: CGFloat)
        -> (NSLayoutManager, NSTextContainer, NSTextStorage) {
        let storage = NSTextStorage(string: text)
        let container = NSTextContainer(size: CGSize(width: width,
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0          // AppKit's default 5pt inset isn't there
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        storage.addAttribute(.font, value: font,
                             range: NSRange(location: 0, length: storage.length))
        return (layout, container, storage)
    }

    /// A font size chosen so the model's glyph widths match the app's, measured
    /// against the caret — the one horizontal position the app reports truly.
    ///
    /// A face we don't have (Slack uses Lato, rarely installed) is typically a
    /// little wider or narrower than the system font, and that error compounds
    /// along a line: by the end of a sentence the squiggle sits a whole word off.
    /// Scaling the size by the ratio the caret reveals corrects the widths *and*
    /// re-wraps at the new width, which keeps the line breaks honest too.
    static func calibratedSize(forCaretAt index: Int, caretX: CGFloat, text: String,
                               block: CGRect, font: NSFont) -> CGFloat? {
        let trueOffset = caretX - block.minX
        // Too close to the left edge to measure anything from.
        guard trueOffset > 30 else { return nil }
        // A wrong glyph width moves the caret two ways at once: every prefix
        // gets wider, and lines wrap at different words, which can dwarf the
        // width error itself. No single ratio separates the two — but both fold
        // into where the model puts the caret, so search the size whose layout
        // puts it nearest to where the app says it really is.
        var best = font.pointSize
        var bestError = CGFloat.greatestFiniteMagnitude
        var size = font.pointSize * 0.80
        while size <= font.pointSize * 1.25 {
            defer { size += 0.25 }
            guard let candidate = NSFont(descriptor: font.fontDescriptor, size: size),
                  let modelled = origin(ofIndex: index, in: text, block: block,
                                        font: candidate) else { continue }
            let error = abs((modelled.x - block.minX) - trueOffset)
            if error < bestError { best = size; bestError = error }
        }
        Log.debug(.detect, "caret width calibration", [
            "caretIndex": index, "trueOffset": Double(trueOffset),
            "chosenSize": Double(best), "residual": Double(bestError),
        ])
        // If even the best size leaves the caret far off, the model is wrong in
        // some way size cannot express — better uncalibrated than misleading.
        guard bestError < 24 else { return nil }
        return best
    }

    /// Where the model puts a single character — used to compare against the
    /// caret, the one position the app will tell us the truth about.
    static func origin(ofIndex index: Int, in text: String, block: CGRect,
                       font: NSFont) -> CGPoint? {
        let ns = text as NSString
        guard index >= 0, index <= ns.length else { return nil }
        let (layout, container, storage) = engine(text: text, font: font, width: block.width)
        return withExtendedLifetime(storage) {
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: min(index, max(ns.length - 1, 0)))
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let point = layout.location(forGlyphAt: glyph)
            return CGPoint(x: block.minX + line.minX + point.x, y: block.minY + line.minY)
        }
    }

    /// Rects for `range`, in AX screen coordinates (top-left origin), split per
    /// line so a wrapped range doesn't come back as one tall box. `offset`
    /// corrects the model against a known-true position (see calibrate).
    static func rects(for range: NSRange, in text: String, block: CGRect,
                      font: NSFont, offset: CGPoint = .zero) -> [CGRect] {
        let (layout, container, storage) = engine(text: text, font: font, width: block.width)
        let ns = text as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return [] }
        defer { withExtendedLifetime(storage) {} }
        layout.ensureLayout(for: container)

        // Even the best-matching font is a little off, and the error grows with
        // every line. Stretching the modelled text onto the block's real height
        // pins the last line where it belongs instead of letting it slide below.
        let modelled = layout.usedRect(for: container).height
        let scale = modelled > 1 ? block.height / modelled : 1

        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var out: [CGRect] = []
        layout.enumerateEnclosingRects(forGlyphRange: glyphs,
                                       withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: container) { rect, _ in
            // Container coordinates are top-left, and so are AX's — no flip.
            out.append(CGRect(x: block.minX + rect.minX + offset.x,
                              y: block.minY + rect.minY * scale + offset.y,
                              width: rect.width,
                              height: rect.height * scale))
        }
        return out
    }

    /// Whether reconstruction is worth attempting: it needs a block whose height
    /// is consistent with the text actually being laid out inside it. A wildly
    /// mismatched height means the frame isn't the text's, and drawing from it
    /// would put squiggles somewhere arbitrary.
    static func plausible(text: String, block: CGRect, font: NSFont) -> Bool {
        guard block.width > 20, block.height > 4, !text.isEmpty else { return false }
        let modelled = modelledHeight(text: text, block: block, font: font)
        // Within a line's worth of the real block, in either direction: more
        // than that and we've wrapped it differently, which no scaling fixes.
        return abs(modelled - block.height) <= max(font.pointSize * 1.8, 8)
    }
}
