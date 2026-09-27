import Foundation

/// Grammar checking via a local LanguageTool server (rule-based, LGPL) instead
/// of an LLM. Same contract as `LLMClient.corrections(in:)` — sentence-level
/// `SentenceCorrection`s — so everything downstream (squiggle diffing, cards,
/// write-back) is engine-agnostic.
///
/// One HTTP request checks the whole field; LanguageTool answers with exact
/// match offsets, which are applied per sentence (first suggestion each).
struct LanguageToolClient {
    let baseURL: URL
    /// "auto" detects per request; a fixed code ("en-US") is steadier on the
    /// short, casual messages that make auto-detection guess wrong.
    var language = "en-US"
    /// Rules that "correct" casual writing into formal writing — the same
    /// line the LLM prompt draws: no capitalising "thanks", no curly quotes,
    /// no whitespace pedantry. Real errors (spelling, agreement, "i" → "I")
    /// stay on.
    var disabledRules = [
        "UPPERCASE_SENTENCE_START",
        "PUNCTUATION_PARAGRAPH_END",
        "WHITESPACE_RULE",
        "COMMA_PARENTHESIS_WHITESPACE",
        "EN_QUOTES",
        "DASH_RULE",
        "EN_UNPAIRED_BRACKETS",
        "EN_UNPAIRED_QUOTES",
        "ENGLISH_WORD_REPEAT_BEGINNING_RULE",
        // Informal register is the writer's choice, not an error.
        "GONNA",                        // gonna → going to
        "INTERJECTIONS_PUNCTUATION",    // haha yeah → haha, yeah
        "PREPOSITION_VERB",             // "the deploy" → "the deployment"
    ]
    var disabledCategories = ["TYPOGRAPHY"]

    struct Match: Sendable {
        let offset: Int      // UTF-16 units (Java string offsets)
        let length: Int
        let replacement: String
        let ruleID: String
    }

    /// Raw matches for `text`, or nil if the server couldn't be reached.
    func check(_ text: String) async -> [Match]? {
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "disabledRules", value: disabledRules.joined(separator: ",")),
            URLQueryItem(name: "disabledCategories", value: disabledCategories.joined(separator: ",")),
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/check"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // URLComponents leaves "+" unescaped, which form decoding reads as a
        // space — escape it so "C++" survives the round trip.
        request.httpBody = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["matches"] as? [[String: Any]] else { return nil }
        return raw.compactMap { m in
            guard let offset = m["offset"] as? Int, let length = m["length"] as? Int,
                  let reps = m["replacements"] as? [[String: Any]],
                  var first = reps.first?["value"] as? String,
                  let rule = (m["rule"] as? [String: Any])?["id"] as? String
            else { return nil }   // no suggestion = nothing we can apply
            // Spelling suggestions come ordered by edit cost, which prefers
            // short words — "abyody" → "body" over "anybody". Among the top
            // few, prefer the one closest in length that keeps the first letter.
            if rule.hasPrefix("MORFOLOGIK"), offset + length <= (text as NSString).length {
                let token = (text as NSString).substring(with: NSRange(location: offset, length: length))
                let candidates = reps.prefix(4).compactMap { $0["value"] as? String }
                func score(_ c: String) -> Int {
                    abs(c.count - token.count) * 2
                        + (c.first?.lowercased() == token.first?.lowercased() ? 0 : 3)
                }
                if let best = candidates.min(by: { score($0) < score($1) }),
                   score(best) < score(first) { first = best }
            }
            // A lowercase word "corrected" into an all-caps acronym is a
            // dictionary guess, not a fix: brb → BRB, npm → NPM, tmrw → TRW.
            let ns = text as NSString
            if offset + length <= ns.length {
                let token = ns.substring(with: NSRange(location: offset, length: length))
                let isLower = token == token.lowercased() && token != token.uppercased()
                let isAcronym = first == first.uppercased() && first != first.lowercased()
                if isLower, isAcronym, first.count > 1 { return nil }
            }
            return Match(offset: offset, length: length, replacement: first, ruleID: rule)
        }
    }

    /// Sentence-level corrections for `text` — the LLMClient contract.
    func corrections(in text: String) async -> [SentenceCorrection] {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count > 1,
              let matches = await check(text), !matches.isEmpty else { return [] }
        let ns = text as NSString
        var out: [SentenceCorrection] = []
        var searchFrom = 0
        for sentence in LLMClient.sentences(in: text) {
            // Sentences are substrings in order; locate each one's UTF-16 range.
            let found = ns.range(of: sentence,
                                 range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            guard found.location != NSNotFound else { continue }
            searchFrom = found.location + found.length
            let inside = matches.filter {
                $0.offset >= found.location && $0.offset + $0.length <= found.location + found.length
            }
            guard !inside.isEmpty else { continue }
            // Apply right-to-left so earlier offsets stay valid.
            let fixed = NSMutableString(string: sentence)
            for m in inside.sorted(by: { $0.offset > $1.offset }) {
                fixed.replaceCharacters(in: NSRange(location: m.offset - found.location,
                                                    length: m.length),
                                        with: m.replacement)
            }
            let original = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            var corrected = (fixed as String).trimmingCharacters(in: .whitespacesAndNewlines)
            // Same casual-writing guard as the LLM path.
            if LLMClient.differsOnlyByCasingOrTerminalStop(corrected, from: original) {
                corrected = original
            }
            if corrected != original {
                out.append(SentenceCorrection(original: original, corrected: corrected))
            }
        }
        return out
    }
}
