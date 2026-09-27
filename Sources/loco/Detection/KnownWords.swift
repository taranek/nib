import Foundation

/// The user's personal dictionary: words that are right even though no
/// dictionary knows them — project names, people, jargon.
/// Matching ignores case, so a known word at a sentence start still matches.
enum KnownWords {
    private static let key = "knownWords"

    /// All words, as the user entered them, sorted for display.
    static func all() -> [String] {
        let words = UserDefaults.standard.stringArray(forKey: key) ?? []
        return words.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func contains(_ word: String) -> Bool {
        let w = normalize(word)
        guard !w.isEmpty else { return false }
        return (UserDefaults.standard.stringArray(forKey: key) ?? []).contains { normalize($0) == w }
    }

    /// Adds `word` (trimmed of spaces and surrounding punctuation). Returns
    /// false when it was empty or already known.
    @discardableResult
    static func add(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !w.isEmpty, !contains(w) else { return false }
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: key) ?? []) + [w], forKey: key)
        return true
    }

    static func remove(_ word: String) {
        let w = normalize(word)
        let kept = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { normalize($0) != w }
        UserDefaults.standard.set(kept, forKey: key)
    }

    /// Drops sentence corrections whose every changed word is a known one — the
    /// engine "fixing" a project name isn't a fix. (A sentence that also has a
    /// real error keeps its correction; engines that report per word, like
    /// LanguageTool, filter before building sentences, so that stays exact.)
    static func filter(_ corrections: [SentenceCorrection]) -> [SentenceCorrection] {
        corrections.filter { c in
            let changed = changedWords(original: c.original, corrected: c.corrected)
            return changed.isEmpty || !changed.allSatisfy(contains)
        }
    }

    /// The words of `original` that `corrected` doesn't keep.
    static func changedWords(original: String, corrected: String) -> [String] {
        let ns = original as NSString
        return WordDiff.changedRanges(original: original, corrected: corrected)
            .map { ns.substring(with: $0) }
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
    }
}
