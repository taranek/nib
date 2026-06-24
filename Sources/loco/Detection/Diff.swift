import Foundation

// MARK: - Word diff
//
// Given the original sentence and the model's corrected version, find which
// words in the original changed — so we can underline exactly those, while the
// fix (and write-back) operates on the whole sentence.

enum WordDiff {
    /// Character ranges (within `original`) of words that aren't preserved in
    /// `corrected`. Case-sensitive so "she" → "She" counts as a change.
    static func changedRanges(original: String, corrected: String) -> [NSRange] {
        let o = tokens(original)
        let c = tokens(corrected).map { $0.text }
        let kept = keptOriginalIndices(o.map { $0.text }, c)
        return o.enumerated()
            .filter { !kept.contains($0.offset) }
            .map { $0.element.range }
    }

    private static func isWord(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57)       // 0-9
            || (c >= 65 && c <= 90) // A-Z
            || (c >= 97 && c <= 122) // a-z
            || c == 39 || c == 0x2019 // ' and ’
    }

    /// Split into word tokens with their ranges.
    private static func tokens(_ s: String) -> [(text: String, range: NSRange)] {
        let ns = s as NSString
        var result: [(String, NSRange)] = []
        var i = 0
        while i < ns.length {
            while i < ns.length, !isWord(ns.character(at: i)) { i += 1 }
            let start = i
            while i < ns.length, isWord(ns.character(at: i)) { i += 1 }
            if i > start {
                let r = NSRange(location: start, length: i - start)
                result.append((ns.substring(with: r), r))
            }
        }
        return result
    }

    /// Indices of `a` that lie on a longest common subsequence with `b` — i.e.
    /// the unchanged words.
    private static func keptOriginalIndices(_ a: [String], _ b: [String]) -> Set<Int> {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1
                                        : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var kept = Set<Int>()
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { kept.insert(i); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return kept
    }
}
