import Foundation

/// Minimal edits between two versions of a text, at word granularity — so a
/// write-back touches only what changed. Retyping a whole sentence flattens
/// everything the editor attached to it (Slack links become plain text);
/// retyping only "wrok" → "work" leaves the link beside it alone.
enum TextHunks {
    struct Hunk: Equatable {
        let range: NSRange        // in the old text (UTF-16)
        let replacement: String
    }

    /// Word, whitespace and punctuation tokens, with UTF-16 ranges.
    private static func tokens(_ s: String) -> [(text: String, range: NSRange)] {
        let ns = s as NSString
        var out: [(String, NSRange)] = []
        var i = 0
        func kind(_ c: unichar) -> Int {
            if let scalar = Unicode.Scalar(c) {
                if CharacterSet.alphanumerics.contains(scalar) || c == 39 || c == 0x2019 { return 0 }
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { return 1 }
            } else {
                return 0   // surrogate halves: part of a word (emoji, rare scripts)
            }
            return 2       // punctuation: one token each
        }
        while i < ns.length {
            let k = kind(ns.character(at: i))
            var j = i + 1
            if k != 2 { while j < ns.length, kind(ns.character(at: j)) == k { j += 1 } }
            let r = NSRange(location: i, length: j - i)
            out.append((ns.substring(with: r), r))
            i = j
        }
        return out
    }

    /// Hunks turning `old` into `new`, in ascending order of position.
    static func diff(_ old: String, _ new: String) -> [Hunk] {
        let a = tokens(old), b = tokens(new)
        let n = a.count, m = b.count
        // LCS table over tokens (texts are sentences or a message — small).
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i].text == b[j].text ? dp[i + 1][j + 1] + 1
                                                      : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        let oldLen = (old as NSString).length
        while i < n || j < m {
            if i < n, j < m, a[i].text == b[j].text { i += 1; j += 1; continue }
            // A run of differences: consume until the sequences agree again.
            let start = i < n ? a[i].range.location : oldLen
            var replacement = ""
            var end = start
            while i < n || j < m {
                if i < n, j < m, a[i].text == b[j].text { break }
                if j < m, i == n || dp[i][j + 1] >= dp[i + 1][j] {
                    replacement += b[j].text; j += 1
                } else {
                    end = a[i].range.location + a[i].range.length; i += 1
                }
            }
            hunks.append(Hunk(range: NSRange(location: start, length: end - start),
                              replacement: replacement))
        }
        return hunks
    }

    /// `old` with `hunks` applied (hunks in ascending order, non-overlapping).
    static func apply(_ hunks: [Hunk], to old: String) -> String {
        let out = NSMutableString(string: old)
        for h in hunks.reversed() { out.replaceCharacters(in: h.range, with: h.replacement) }
        return out as String
    }

    static func overlaps(_ r: NSRange, _ protected: [NSRange]) -> Bool {
        protected.contains { p in
            // Touching counts: typing right at a link's edge can extend or
            // swallow it in rich editors.
            r.location <= p.location + p.length && p.location <= r.location + r.length
        }
    }

    /// Corrections with every edit inside a protected range (a link's text)
    /// reverted; corrections left with no edits are dropped. `fullText` is the
    /// field text the protected ranges index into.
    static func protect(_ corrections: [SentenceCorrection], in fullText: String,
                        protected: [NSRange]) -> [SentenceCorrection] {
        guard !protected.isEmpty else { return corrections }
        let ns = fullText as NSString
        return corrections.compactMap { c in
            let at = ns.range(of: c.original)
            guard at.location != NSNotFound else { return c }
            let kept = diff(c.original, c.corrected).filter {
                !overlaps(NSRange(location: at.location + $0.range.location, length: $0.range.length),
                          protected)
            }
            guard !kept.isEmpty else { return nil }
            return SentenceCorrection(original: c.original, corrected: apply(kept, to: c.original))
        }
    }
}
