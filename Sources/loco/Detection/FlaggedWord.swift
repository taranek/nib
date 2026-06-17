import CoreGraphics
import Foundation

/// One flagged span with everything the overlay + card + write-back need.
struct FlaggedWord {
    let word: String          // the exact wrong substring
    let replacement: String   // the suggested fix
    let message: String       // "wrong → fix" for the card
    let category: String      // e.g. "Grammar"
    let rect: CGRect          // Cocoa coords (bottom-left origin), screen space
    let range: NSRange?       // native write-back via AX (nil for browsers)
    let key: String           // match key — the wrong substring, verbatim
    let occurrence: Int       // Nth match of this key — disambiguates duplicates

    /// Stable identity for hover/dismiss bookkeeping.
    var id: String { "\(key)#\(occurrence)" }
}
