import Foundation
import NaturalLanguage

// MARK: - Local LLM (llama.cpp server)
//
// loco runs a bundled `llama-server` (llama.cpp's OpenAI-compatible HTTP server)
// as a child process and talks to it over http://127.0.0.1:<port>. The server
// loads one GGUF model and exposes /v1/chat/completions. We use a JSON-schema
// response format so the model returns structured grammar corrections.

/// One grammar/spelling correction: the exact original substring and its fix.
struct Correction: Equatable {
    let wrong: String
    let fix: String
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

    init(port: Int = 18080) { self.port = port }

    var chatURL: URL { URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")! }
    private var healthURL: URL { URL(string: "http://127.0.0.1:\(port)/health")! }

    /// Spawn llama-server and poll until it's listening. Idempotent-ish: a second
    /// call while running is a no-op.
    func start() {
        guard process == nil else { return }
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
            print("🧠 LLM: starting llama-server (model: \(URL(fileURLWithPath: model).lastPathComponent))")
            Task { await pollUntilReady() }
        } catch {
            status = .failed(error.localizedDescription)
            print("⚠️ LLM: failed to launch: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminate()
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

    private static let systemPrompt = """
    You are a precise grammar and spelling checker. You are given one sentence to \
    check. Find every grammar, spelling, and punctuation mistake in it. Return JSON \
    only. For each mistake, set "wrong" to the exact substring copied verbatim from \
    the sentence (character-for-character, a whole word or short phrase), and "fix" \
    to its corrected replacement. Do not flag correct text. If the sentence has no \
    mistakes, return an empty array.
    """

    private static let schema: [String: Any] = [
        "type": "json_schema",
        "json_schema": [
            "name": "corrections",
            "strict": true,
            "schema": [
                "type": "object",
                "properties": [
                    "corrections": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "wrong": ["type": "string"],
                                "fix": ["type": "string"],
                            ],
                            "required": ["wrong", "fix"],
                        ],
                    ],
                ],
                "required": ["corrections"],
            ],
        ],
    ]

    /// Check the input sentence by sentence (concurrently) and merge the
    /// corrections. Each correction's `wrong` is verbatim from its sentence, so
    /// it's locatable in the full text.
    func check(text: String) async -> [Correction] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return [] }

        let sentences = Self.sentences(in: text)
        if sentences.count <= 1 {
            return await checkSentence(trimmed)
        }

        var collected: [Correction] = []
        await withTaskGroup(of: [Correction].self) { group in
            for sentence in sentences {
                group.addTask { await checkSentence(sentence) }
            }
            for await result in group { collected.append(contentsOf: result) }
        }

        // Dedup across sentences (same mistake repeated).
        var seen = Set<String>()
        return collected.filter { seen.insert("\($0.wrong)|\($0.fix)").inserted }
    }

    /// Check one sentence in isolation.
    private func checkSentence(_ sentence: String) async -> [Correction] {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return [] }

        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": sentence],
            ],
            "temperature": 0,
            "max_tokens": 512,
            "response_format": Self.schema,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 30

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return [] }

        // Validate against the sentence so phrases are scoped to where they belong.
        return Self.parse(content, in: sentence)
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

    /// Parse the model's JSON content into corrections, keeping only verbatim,
    /// non-trivial, deduplicated entries.
    static func parse(_ content: String, in text: String) -> [Correction] {
        // The schema yields clean JSON, but be defensive about stray fences.
        let json = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["corrections"] as? [[String: Any]] else { return [] }

        var seen = Set<String>()
        var result: [Correction] = []
        for item in items {
            guard let wrong = item["wrong"] as? String,
                  let fix = item["fix"] as? String,
                  !wrong.isEmpty, wrong != fix,
                  text.contains(wrong),            // must be locatable verbatim
                  seen.insert(wrong).inserted else { continue }
            result.append(Correction(wrong: wrong, fix: fix))
        }
        return result
    }
}
