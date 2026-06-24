import CoreGraphics
import Foundation

/// A changed-word region to underline, carrying the whole-sentence correction
/// it belongs to. Hovering any region for a sentence shows the same corrected
/// sentence; accepting replaces the entire sentence.
struct FlaggedWord {
    let rect: CGRect          // Cocoa coords (bottom-left origin), screen space
    let original: String      // the sentence as written
    let corrected: String     // the corrected sentence
    let range: NSRange?       // native write-back range of the sentence (nil for browsers)
    let sentenceID: String    // identity for hover grouping + dismiss

    var id: String { sentenceID }
}
