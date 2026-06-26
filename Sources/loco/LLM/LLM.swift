import Foundation
import NaturalLanguage

// MARK: - Local LLM (llama.cpp server)
//
// loco runs a bundled `llama-server` (llama.cpp's OpenAI-compatible HTTP server)
// as a child process and talks to it over http://127.0.0.1:<port>. The server
// loads one GGUF model and exposes /v1/chat/completions. We use a JSON-schema
// response format so the model returns structured grammar corrections.

/// A sentence and its corrected form.
struct SentenceCorrection: Equatable, Sendable {
    let original: String
    let corrected: String
}

/// The available ways to rewrite a selection.
enum RewriteStyle: String, CaseIterable, Sendable {
    case grammar, rephrase, shorten

    /// Label shown in the card's style picker.
    var label: String {
        switch self {
        case .grammar: return "Grammar"
        case .rephrase: return "Rephrase"
        case .shorten: return "Shorten"
        }
    }

    /// The instruction handed to the model.
    var instruction: String {
        switch self {
        case .grammar:
            return "Correct only the spelling, grammar, and punctuation in the user's "
                + "text, changing as little as possible. Keep the original wording, "
                + "meaning, tone, and length. If there are no errors, return the text "
                + "unchanged. Put the result in the 'rewrite' field."
        case .rephrase:
            return "Rephrase the user's text using different wording while keeping the "
                + "same meaning and language, in clear natural English. Put the result "
                + "in the 'rewrite' field."
        case .shorten:
            return "Make the user's text more concise: keep the same meaning and language "
                + "but use fewer words, in clear natural English. Put the result in the "
                + "'rewrite' field."
        }
    }
}

/// Process-wide cache of sentence → corrected sentence. Safe because greedy
/// decoding is deterministic. Bounded with simple FIFO eviction.
actor GrammarCache {
    static let shared = GrammarCache()
    private var store: [String: String] = [:]
    private var order: [String] = []
    private let limit = 1000

    func get(_ key: String) -> String? { store[key] }

    func set(_ key: String, _ value: String) {
        if store[key] == nil { order.append(key) }
        store[key] = value
        if order.count > limit {
            let evicted = order.removeFirst()
            store[evicted] = nil
        }
    }
}

// MARK: - Paths & bundling

/// Resolves (and seeds) loco's own copy of the binary + model under
/// Application Support, so the LLM is self-contained rather than wired to
/// another app's paths. Env overrides win for development.
enum LLMPaths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("loco", isDirectory: true)
    }

    static var binDir: URL { supportDir.appendingPathComponent("bin", isDirectory: true) }
    static var modelsDir: URL { supportDir.appendingPathComponent("models", isDirectory: true) }

    /// Known locations to seed from on first run (so a working binary/model we
    /// already have on disk isn't re-downloaded or rebuilt). Best-effort.
    private static let seedBinary = URL(fileURLWithPath:
        "/Users/tomasztaranek/code/electron-llm/vendor/llama.cpp/build/bin/llama-server")
    private static let seedModelsDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("electron-llm/models", isDirectory: true)

    /// Path to the llama-server binary, seeding loco's copy if needed.
    static func resolveBinary() -> String? {
        if let env = ProcessInfo.processInfo.environment["LOCO_LLAMA_SERVER"] { return env }

        let fm = FileManager.default
        let dest = binDir.appendingPathComponent("llama-server")
        if fm.isExecutableFile(atPath: dest.path) { return dest.path }

        // Seed by copying the known-good binary into loco's own dir.
        if fm.fileExists(atPath: seedBinary.path) {
            try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            try? fm.copyItem(at: seedBinary, to: dest)
            if fm.isExecutableFile(atPath: dest.path) { return dest.path }
        }
        return nil
    }

    /// Path to a GGUF model, seeding loco's dir with a symlink to an existing
    /// model if present (avoids duplicating multi-GB files).
    static func resolveModel() -> String? {
        if let env = ProcessInfo.processInfo.environment["LOCO_MODEL"] { return env }

        let fm = FileManager.default
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        // Already have a model in loco's dir?
        if let existing = firstGGUF(in: modelsDir) { return existing }

        // Seed: symlink any GGUF we can find in the known models dir.
        if let seed = firstGGUF(in: seedModelsDir) {
            let link = modelsDir.appendingPathComponent(URL(fileURLWithPath: seed).lastPathComponent)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: seed)
            if fm.fileExists(atPath: link.path) { return link.path }
        }
        return nil
    }

    static func modelName() -> String? {
        resolveModel().map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private static func firstGGUF(in dir: URL) -> String? {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return items.sorted().first { $0.hasSuffix(".gguf") }
            .map { dir.appendingPathComponent($0).path }
    }
}

// MARK: - Server

@MainActor
final class LLMServer {
    enum Status: Equatable {
        case stopped, starting, ready
        case failed(String)
    }

    private(set) var status: Status = .stopped {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    var onStatusChange: ((Status) -> Void)?

    let port: Int
    private var process: Process?
    private var owns = false   // did we spawn the server (so we may kill it)?

    init(port: Int = 18080) { self.port = port }

    var chatURL: URL { URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")! }
    private var healthURL: URL { URL(string: "http://127.0.0.1:\(port)/health")! }

    /// Attach to a server already listening on the port (e.g. one left warm by a
    /// previous run during dev), otherwise spawn our own.
    func start() {
        guard process == nil, status != .ready else { return }
        status = .starting
        Task { await startOrAttach() }
    }

    private func startOrAttach() async {
        if await isHealthy() {
            owns = false
            status = .ready
            print("🧠 LLM: attached to running server on port \(port)")
            return
        }
        spawn()
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(data: data, encoding: .utf8)?.contains("\"ok\"") == true
    }

    /// Spawn llama-server and poll until it's listening.
    private func spawn() {
        guard let bin = LLMPaths.resolveBinary() else {
            status = .failed("llama-server binary not found")
            print("⚠️ LLM: no llama-server binary. Set LOCO_LLAMA_SERVER or place it in \(LLMPaths.binDir.path)")
            return
        }
        guard let model = LLMPaths.resolveModel() else {
            status = .failed("no GGUF model found")
            print("⚠️ LLM: no model. Set LOCO_MODEL or place a .gguf in \(LLMPaths.modelsDir.path)")
            return
        }

        status = .starting
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = [
            "-m", model,
            "--port", String(port),
            "-ngl", "999",
            "-c", "8192",
            "--parallel", "4",        // overlap the per-sentence requests
            "--no-mmap",
            "--reasoning-budget", "0",
            "--jinja",
        ]
        // Drain output so the pipe buffer never fills (which would stall the server).
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if ProcessInfo.processInfo.environment["LOCO_DEBUG"] != nil,
               let s = String(data: data, encoding: .utf8) {
                FileHandle.standardError.write(Data("[llama] \(s)".utf8))
            }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                if self?.status == .ready || self?.status == .starting {
                    self?.status = .failed("llama-server exited")
                }
            }
        }

        do {
            try p.run()
            process = p
            owns = true
            print("🧠 LLM: starting llama-server (model: \(URL(fileURLWithPath: model).lastPathComponent))")
            Task { await pollUntilReady() }
        } catch {
            status = .failed(error.localizedDescription)
            print("⚠️ LLM: failed to launch: \(error.localizedDescription)")
        }
    }

    func stop() {
        if owns { process?.terminate() }   // never kill a server we merely attached to
        process = nil
        status = .stopped
    }

    private func pollUntilReady() async {
        let deadline = Date().addingTimeInterval(120)
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2
        while Date() < deadline {
            if process == nil { return }   // exited
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               String(data: data, encoding: .utf8)?.contains("\"ok\"") == true {
                status = .ready
                print("🧠 LLM: ready on port \(port)")
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if status != .ready { status = .failed("startup timed out") }
    }
}

// MARK: - Client

/// Sends grammar-check requests to the local server and parses corrections.
struct LLMClient {
    let chatURL: URL

    private static let correctPrompt = """
    You correct a single sentence. Fix ONLY clear spelling, grammar, and \
    punctuation errors, changing as little as possible. Put the result in the \
    "corrected" field.

    Rules:
    - Keep contractions (don't, doesn't, it's, I'm, they're, etc.) — never expand them.
    - Keep sentence-ending punctuation (. ! ?) exactly as written.
    - Preserve ALL of the original wording and content: never delete or reword \
    parentheticals (…), quotes, names, code, or anything that is already correct.
    - Do not rewrite for style or concision. If the sentence has no clear error, \
    return it exactly unchanged.
    """

    /// Worked examples — small models follow these far better than rules alone
    /// (capitalization, idiomatic usage, keeping correct sentences unchanged).
    private static let fewShot: [[String: Any]] = [
        ["role": "user", "content": "she doesn't like it alot."],
        ["role": "assistant", "content": #"{"corrected":"She doesn't like it much."}"#],
        ["role": "user", "content": "i has went to teh store yesterday."],
        ["role": "assistant", "content": #"{"corrected":"I went to the store yesterday."}"#],
        ["role": "user", "content": "Context for the other agent (the actual fix): this config is correct"],
        ["role": "assistant", "content": #"{"corrected":"Context for the other agent (the actual fix): this config is correct"}"#],
    ]

    private static let correctSchema: [String: Any] = [
        "type": "json_schema",
        "json_schema": [
            "name": "corrected",
            "strict": true,
            "schema": [
                "type": "object",
                "properties": ["corrected": ["type": "string"]],
                "required": ["corrected"],
            ],
        ],
    ]

    /// Correct the input sentence by sentence (concurrently). Returns only the
    /// sentences the model actually changed, paired with their corrections.
    func corrections(in text: String) async -> [SentenceCorrection] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return [] }

        let sentences = Self.sentences(in: text)
        var out: [SentenceCorrection] = []
        await withTaskGroup(of: SentenceCorrection?.self) { group in
            for sentence in sentences {
                group.addTask { await correctSentence(sentence) }
            }
            for await result in group { if let result { out.append(result) } }
        }
        return out
    }

    /// Correct one sentence in isolation, caching successful results. Returns nil
    /// if the model left it unchanged (or the request failed).
    private func correctSentence(_ sentence: String) async -> SentenceCorrection? {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return nil }

        if let cached = await GrammarCache.shared.get(trimmed) {
            return cached == trimmed ? nil : SentenceCorrection(original: trimmed, corrected: cached)
        }

        let messages: [[String: Any]] = [["role": "system", "content": Self.correctPrompt]]
            + Self.fewShot
            + [["role": "user", "content": trimmed]]
        let body: [String: Any] = [
            "messages": messages,
            "temperature": 0,
            "max_tokens": 512,
            "response_format": Self.correctSchema,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 30

        // A failed request returns nil WITHOUT caching.
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }

        let json = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let corrected = (obj["corrected"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !corrected.isEmpty else { return nil }

        await GrammarCache.shared.set(trimmed, corrected)
        return corrected == trimmed ? nil : SentenceCorrection(original: trimmed, corrected: corrected)
    }

    // MARK: Text actions

    func rewrite(style: RewriteStyle, _ text: String) async -> String? {
        await rewrite(style.instruction, text)
    }

    /// JSON schema for a single rewrite — constraining the output to a JSON
    /// object forces the model straight to the answer (no chain-of-thought prose).
    private static let rewriteSchema: [String: Any] = [
        "type": "json_schema",
        "json_schema": [
            "name": "rewrite",
            "strict": true,
            "schema": [
                "type": "object",
                "properties": ["rewrite": ["type": "string"]],
                "required": ["rewrite"],
            ],
        ],
    ]

    /// One rewrite turn; returns the model's text from the JSON `rewrite` field.
    private func rewrite(_ instruction: String, _ text: String) async -> String? {
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": instruction],
                ["role": "user", "content": text],
            ],
            "temperature": 0,
            "max_tokens": 1024,
            "response_format": Self.rewriteSchema,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 60

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }

        let json = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rewrite = obj["rewrite"] as? String else { return nil }
        let cleaned = rewrite.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Split text into sentences (Apple's tokenizer), dropping empty fragments.
    static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
            if !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(sentence)
            }
            return true
        }
        return result
    }
}
