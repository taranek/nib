import Foundation

// MARK: - Dictionary linter (offline fallback)
//
// A tiny local rule engine used only when the LLM isn't ready yet, so loco still
// catches the obvious misspellings. The LLM is the primary grammar backend.

enum Linter {
    static let misspellings: [String: String] = [
        "teh": "the", "recieve": "receive", "dont": "don't", "wont": "won't",
        "cant": "can't", "alot": "a lot", "definately": "definitely",
        "occured": "occurred", "seperate": "separate", "thier": "their",
        "wich": "which", "becuase": "because", "wierd": "weird", "freind": "friend",
        "adress": "address", "tommorow": "tomorrow", "untill": "until",
    ]

    /// Scan the raw text value for known misspellings.
    static func words(in text: String) -> [(word: String, replacement: String, range: NSRange)] {
        guard !text.isEmpty else { return [] }
        var result: [(String, String, NSRange)] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: .byWords) { sub, range, _, _ in
            guard let sub, let fix = misspellings[sub.lowercased()] else { return }
            let cased = matchCase(fix, like: sub)
            result.append((String(sub), cased, NSRange(range, in: text)))
        }
        return result
    }

    /// Preserve a leading capital from the original word.
    static func matchCase(_ replacement: String, like original: String) -> String {
        guard let first = original.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
}
