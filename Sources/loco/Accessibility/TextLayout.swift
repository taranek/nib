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
    /// Rects for `range`, in AX screen coordinates (top-left origin), split per
    /// line so a wrapped range doesn't come back as one tall box.
    static func rects(for range: NSRange, in text: String, block: CGRect,
                      fontSize: CGFloat) -> [CGRect] {
        let storage = NSTextStorage(string: text)
        let container = NSTextContainer(size: CGSize(width: block.width,
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0          // AppKit's default 5pt inset isn't there
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize),
                             range: NSRange(location: 0, length: storage.length))

        let ns = text as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return [] }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)

        var out: [CGRect] = []
        layout.enumerateEnclosingRects(forGlyphRange: glyphs,
                                       withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: container) { rect, _ in
            // Container coordinates are top-left, and so are AX's — no flip.
            out.append(CGRect(x: block.minX + rect.minX, y: block.minY + rect.minY,
                              width: rect.width, height: rect.height))
        }
        return out
    }

    /// Whether reconstruction is worth attempting: it needs a block whose height
    /// is consistent with the text actually being laid out inside it. A wildly
    /// mismatched height means the frame isn't the text's, and drawing from it
    /// would put squiggles somewhere arbitrary.
    static func plausible(text: String, block: CGRect, fontSize: CGFloat) -> Bool {
        guard block.width > 20, block.height > 4, !text.isEmpty else { return false }
        let storage = NSTextStorage(string: text)
        let container = NSTextContainer(size: CGSize(width: block.width,
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize),
                             range: NSRange(location: 0, length: storage.length))
        layout.ensureLayout(for: container)
        let modelled = layout.usedRect(for: container).height
        // Within a line's worth of the real block, in either direction.
        return abs(modelled - block.height) <= max(fontSize * 1.8, 8)
    }
}
