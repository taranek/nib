import Foundation

/// Headless grammar-engine evaluation: `loco --grammar-eval …` runs a corpus
/// through the PRODUCTION engine code (the real LLMClient prompt + guards, or
/// the real LanguageToolClient) and scores it, so engine changes are measured
/// on this machine instead of eyeballed.
///
///   loco --grammar-eval --corpus Tests/grammar-corpus.json \
///        --engine llm --llm-url http://127.0.0.1:18099/v1/chat/completions
///   loco --grammar-eval --corpus Tests/grammar-corpus.json \
///        --engine lt --lt-url http://127.0.0.1:8081 [--lt-lang auto]
///
/// Scoring: an "unchanged" case passes only if the engine leaves the text
/// alone (false positives are the costliest failure — they squiggle correct
/// writing). An error case passes when every `must` substring is in the
/// output and every `mustNot` substring is gone.
enum GrammarEval {
    struct Case: Decodable {
        let id: String
        let cat: String
        let text: String
        var lang: String?
        var unchanged: Bool?
        var must: [String]?
        var mustNot: [String]?
    }

    static func arg(_ name: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func run(arguments args: [String]) async -> Int32 {
        guard let corpusPath = arg("--corpus", args),
              let data = FileManager.default.contents(atPath: corpusPath),
              let cases = try? JSONDecoder().decode([Case].self, from: data) else {
            print("usage: loco --grammar-eval --corpus FILE --engine llm|lt [...]")
            return 2
        }
        let engine = arg("--engine", args) ?? "lt"
        let ltLang = arg("--lt-lang", args) ?? "en-US"
        let only = arg("--only", args)   // category filter

        let check: (Case) async -> [SentenceCorrection]
        switch engine {
        case "llm":
            let url = URL(string: arg("--llm-url", args)
                          ?? "http://127.0.0.1:18080/v1/chat/completions")!
            let client = LLMClient(chatURL: url)
            check = { await client.corrections(in: $0.text) }
        default:
            let url = URL(string: arg("--lt-url", args) ?? "http://127.0.0.1:8081")!
            check = { c in
                var client = LanguageToolClient(baseURL: url)
                // "auto" = one detector for everything; otherwise honour a
                // per-case language hint (the Polish rows), defaulting to ltLang.
                client.language = ltLang == "auto" ? "auto" : (c.lang ?? ltLang)
                return await client.corrections(in: c.text)
            }
        }

        let selected = cases.filter { only == nil || $0.cat == only }
        // Warm-up: first request pays JIT / prompt-cache costs.
        if let first = selected.first { _ = await check(first) }

        var results: [[String: Any]] = []
        var byCat: [String: (pass: Int, total: Int)] = [:]
        var latencies: [Double] = []
        print("engine=\(engine)\(engine == "lt" ? " lang=\(ltLang)" : "") cases=\(selected.count)\n")
        for c in selected {
            let t0 = DispatchTime.now()
            let fixes = await check(c)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            latencies.append(ms)
            var output = c.text
            for f in fixes {
                if let r = output.range(of: f.original) {
                    output.replaceSubrange(r, with: f.corrected)
                }
            }
            let pass: Bool
            if c.unchanged == true {
                pass = output == c.text
            } else {
                pass = (c.must ?? []).allSatisfy { output.contains($0) }
                    && (c.mustNot ?? []).allSatisfy { !output.contains($0) }
            }
            var tally = byCat[c.cat] ?? (0, 0)
            tally.total += 1
            if pass { tally.pass += 1 }
            byCat[c.cat] = tally
            let mark = pass ? "PASS" : "FAIL"
            let shown = output == c.text ? "(unchanged)" : "→ \(output)"
            print("\(mark)  \(String(format: "%6.0fms", ms))  [\(c.id)] \(c.text)\n              \(shown)")
            results.append(["id": c.id, "cat": c.cat, "pass": pass, "ms": ms,
                            "input": c.text, "output": output])
        }

        let sorted = latencies.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let passed = results.filter { $0["pass"] as? Bool == true }.count
        print("\n=== \(engine) summary ===")
        for (cat, t) in byCat.sorted(by: { $0.key < $1.key }) {
            print(String(format: "  %-10@ %2d/%2d", cat as NSString, t.pass, t.total))
        }
        print(String(format: "  overall    %2d/%2d   latency p50 %.0fms  p95 %.0fms",
                     passed, results.count, pct(0.5), pct(0.95)))

        if let out = arg("--out", args),
           let json = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]) {
            FileManager.default.createFile(atPath: out, contents: json)
        }
        return 0
    }
}
