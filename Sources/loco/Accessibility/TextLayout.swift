import AppKit
import CoreText
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
    /// Register bundled fonts (Lato, which Slack renders in) so the layout model
    /// can reproduce another app's text exactly instead of guessing with the
    /// system face. Called once at launch.
    static func registerBundledFonts() {
        guard let url = Bundle.module.url(forResource: "Lato-Regular",
                                          withExtension: "ttf", subdirectory: "fonts")
            ?? Bundle.module.url(forResource: "Lato-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// Fonts to try. The app doesn't name its font, so the one whose layout best
    /// reproduces the block's real height is the closest model of it. Slack uses
    /// Lato; other Electron apps mostly use the system face.
    /// Slack renders in Lato (bundled and registered at launch), so it's tried
    /// first and used whenever its layout is plausible — height-matching alone
    /// can't tell it from the system font, but its glyph widths differ, and that
    /// width difference is exactly the squiggle drift. The rest are fallbacks
    /// for other apps whose font we don't know.
    private static let candidates = ["Lato", "Lato-Regular", "Helvetica Neue", "Arial"]

    /// The font whose layout height comes closest to the block's actual height,
    /// which is the only ground truth the app gives us. A wrong font drifts a
    /// little on every line and the error accumulates down the message, so this
    /// is worth the few layout passes — and the answer is cached by the caller.
    static func calibratedFont(text: String, block: CGRect, fontSize: CGFloat) -> NSFont {
        let fonts = candidates.compactMap { NSFont(name: $0, size: fontSize) }
            + [NSFont.systemFont(ofSize: fontSize)]
        // A known font that lays the text out to the block's real height is the
        // right answer, not merely the least-bad one — so take the first that
        // fits within a line, in preference order (Lato first).
        let tolerance = max(fontSize * 1.2, 6)
        for font in fonts
        where abs(height(of: text, font: font, width: block.width) - block.height) <= tolerance {
            return font
        }
        // None fits: the least-bad by height.
        return fonts.min {
            abs(height(of: text, font: $0, width: block.width) - block.height)
                < abs(height(of: text, font: $1, width: block.width) - block.height)
        } ?? NSFont.systemFont(ofSize: fontSize)
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

    /// Rects for `range`, in AX screen coordinates (top-left origin), split per
    /// line so a wrapped range doesn't come back as one tall box. `offset`
    /// corrects the model against a known-true position (see calibrate).
    static func rects(for range: NSRange, in text: String, block: CGRect,
                      font: NSFont) -> [CGRect] {
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
            out.append(CGRect(x: block.minX + rect.minX,
                              y: block.minY + rect.minY * scale,
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
