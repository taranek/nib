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
    case grammar, rephrase, translate

    /// Label shown in the card's style picker.
    var label: String {
        switch self {
        case .grammar: return "Grammar"
        case .rephrase: return "Rephrase"
        case .translate: return "Translate"
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
                + "same meaning and language, in clear, natural prose. Put the result "
                + "in the 'rewrite' field."
        case .translate:
            return "Translate the user's text into English. Detect the source language "
                + "automatically and produce natural, fluent English that preserves the "
                + "meaning and tone. If the text is already English, return it unchanged. "
                + "Put the result in the 'rewrite' field."
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
        let dir = base.appendingPathComponent("Nib", isDirectory: true)
        // One-time migration from the pre-rename dir so downloaded models and
        // onboarding state carry over (the loco→Notavo rename lost them).
        let fm = FileManager.default
        let old = base.appendingPathComponent("Notavo", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: dir)
        }
        return dir
    }

    static var binDir: URL { supportDir.appendingPathComponent("bin", isDirectory: true) }
    static var modelsDir: URL { supportDir.appendingPathComponent("models", isDirectory: true) }
    static var logsDir: URL { supportDir.appendingPathComponent("logs", isDirectory: true) }
    /// llama-server output (model load/connect failures land here).

    /// First-run onboarding flag, persisted as JSON alongside bin/ and models/ so
    /// it survives relaunches. Delete the file (or set the flag false) to replay
    /// onboarding.
    static var stateURL: URL { supportDir.appendingPathComponent("state.json", isDirectory: false) }

    static func onboardingCompleted() -> Bool {
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return obj["onboardingCompleted"] as? Bool ?? false
    }

    static func setOnboardingCompleted(_ completed: Bool) {
        try? FileManager.default.createDirectory(
            at: supportDir, withIntermediateDirectories: true)
        let obj: [String: Any] = [
            "onboardingCompleted": completed,
            "completedAt": completed ? ISO8601DateFormatter().string(from: Date()) : NSNull(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: stateURL)
        }
    }

    /// Path to the llama-server binary:
    ///   1. LOCO_LLAMA_SERVER override (dev)
    ///   2. bundled in the app (Resources/bin/llama-server) — the shipped app
    ///   3. a copy in loco's support dir (dev / manual install)
    static func resolveBinary() -> String? {
        if let env = ProcessInfo.processInfo.environment["LOCO_LLAMA_SERVER"] { return env }

        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("bin/llama-server").path,
           fm.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let dest = binDir.appendingPathComponent("llama-server")
        if fm.isExecutableFile(atPath: dest.path) { return dest.path }
        return nil
    }

    /// Path to a GGUF model. The user provides one (Settings → Change, or by
    /// dropping a .gguf into the models dir); nil until then.
    static func resolveModel() -> String? {
        if let saved = UserDefaults.standard.string(forKey: "modelPath"),
           FileManager.default.fileExists(atPath: saved) {
            return saved
        }
        if let env = ProcessInfo.processInfo.environment["LOCO_MODEL"] { return env }
        try? FileManager.default.createDirectory(
            at: modelsDir, withIntermediateDirectories: true)
        return firstGGUF(in: modelsDir)
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
    /// Pinned model for task-specific servers; nil = the app's default model.
    let fixedModelPath: String?
    /// Last time a task routed to this server (drives idle shutdown).
    var lastUsed = Date()
    private var process: Process?
    private var owns = false   // did we spawn the server (so we may kill it)?

    init(port: Int = 18080, modelPath: String? = nil) {
        self.port = port
        self.fixedModelPath = modelPath
    }

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
            Log.info(.server, "attached to a server already running", ["port": port])
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
            Log.error(.server, "no llama-server binary", ["expected": LLMPaths.binDir.path])
            return
        }
        guard let model = fixedModelPath ?? LLMPaths.resolveModel(),
              FileManager.default.fileExists(atPath: model) else {
            status = .failed("no GGUF model found")
            Log.error(.server, "no model available", ["expected": LLMPaths.modelsDir.path])
            return
        }

        // Reclaim the port from any llama-server we orphaned in a previous run
        // (e.g. after a crash/force-quit), otherwise the new one can't bind it and
        // exits immediately.
        killStaleServers()

        status = .starting
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = [
            "-m", model,
            "--port", String(port),
            "-ngl", "999",
            "-c", "8192",
            "--parallel", "4",        // overlap the per-sentence requests
            "--reasoning-budget", "0",
            "--jinja",
        ]
        // Drain output so the pipe buffer never fills (which would stall the server).
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        outputPipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF: the child is gone. Without clearing this, Foundation's
                // dispatch read source keeps firing on the dead pipe forever,
                // burning a core per stopped server for the app's lifetime.
                handle.readabilityHandler = nil
                return
            }
            // Tee llama-server output to a log file so model-load failures are
            // diagnosable even when the app is launched via Finder/`open` (no
            // stdout). Also reachable via Settings → Open log.
            // Into the same file as everything else, in order: the model
            // server's own output is half the story when a check is slow.
            if let text = String(data: data, encoding: .utf8) { Log.raw(.llama, text) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                if self?.status == .ready || self?.status == .starting {
                    self?.status = .failed("llama-server exited")
                }
            }
        }

        // Start the log fresh for the main server; task servers append (they

        do {
            try p.run()
            process = p
            owns = true
            launchedAt = DispatchTime.now()
            Log.info(.server, "starting llama-server", [
                "model": URL(fileURLWithPath: model).lastPathComponent, "port": port])
            Task { await pollUntilReady() }
        } catch {
            status = .failed(error.localizedDescription)
            Log.error(.server, "failed to launch llama-server", ["error": error.localizedDescription])
        }
    }

    /// Kept so the read source can be unregistered when the process goes away.
    private var outputPipe: Pipe?
    /// When the current process was launched, so "ready" can report the wait.
    private var launchedAt = DispatchTime.now()

    private func closeOutputPipe() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? outputPipe?.fileHandleForReading.close()
        outputPipe = nil
    }

    func stop() {
        closeOutputPipe()
        if owns { process?.terminate() }   // never kill a server we merely attached to
        process = nil
        status = .stopped
    }

    /// SIGKILL any llama-server bound to our port (orphans from a crash, or the one
    /// we just terminated). SIGKILL releases the socket immediately so a fresh
    /// spawn can bind it.
    private func killStaleServers() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-9", "-f", "llama-server.*--port \(port)"]
        try? task.run()
        task.waitUntilExit()
        usleep(250_000)   // give the kernel a moment to release the port
    }

    /// Stop the current server and start a fresh one with the newly-resolved model.
    /// Forces a respawn (never re-attaches to a still-running server, which could be
    /// serving the old model).
    func restart() {
        let old = owns ? process : nil
        process = nil
        owns = false
        status = .starting
        Task.detached {
            old?.terminate()
            old?.waitUntilExit()
            await MainActor.run { self.spawn() }
        }
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
                Log.info(.server, "server ready", ["port": port, "ms": Log.ms(since: launchedAt)])
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
    /// Output-validation quirks of the serving model (from the manifest);
    /// generic prompt-echo markers are always applied on top.
    var echoMarkers: [String] = []
    var maxGrowth: Double = 2.0

    private static let correctPrompt = """
    You improve one sentence from a message someone is writing. Read the whole \
    sentence before changing anything, and return your version in the \
    "corrected" field.

    Fix spelling, grammar and punctuation — and also fix the sentence when it \
    reads badly: awkward word order, a clumsy or roundabout phrasing, a word \
    that doesn't say what the writer means. Make it read the way a careful \
    writer would have written it the first time.

    Rules:
    - Keep the writer's meaning, facts and intent exactly. Never add information.
    - Keep their voice and register: casual stays casual, terse stays terse. \
    Keep contractions (don't, it's, I'm) — never expand them.
    - Match how they capitalise and punctuate. Do NOT add a capital letter or a \
    full stop the writer left off — a short chat message like "thanks", "on my \
    way", or "sounds good" is complete as written; return it unchanged.
    - Only fix capitalisation or punctuation when leaving it would be a real \
    error in their own register (a misspelling, "i" for "I" mid-sentence, a \
    missing apostrophe in a contraction), never to make casual text look formal.
    - Leave names, quotes, code, URLs and parentheticals alone.
    - Don't pad. A shorter, plainer sentence is better than a longer one.
    - If the message already reads well, return it exactly unchanged.
    """

    /// Worked examples — small models follow these far better than rules alone
    /// (capitalization, idiomatic usage, keeping correct sentences unchanged).
    private static let fewShot: [[String: Any]] = [
        ["role": "user", "content": "she doesn't like it alot."],
        ["role": "assistant", "content": #"{"corrected":"She doesn't like it much."}"#],
        ["role": "user", "content": "i has went to teh store yesterday."],
        ["role": "assistant", "content": #"{"corrected":"I went to the store yesterday."}"#],
        // Word order and phrasing, not just spelling — the point of reading the
        // whole sentence rather than checking words one at a time.
        ["role": "user", "content": "Tomorrow can we the meeting move to 3pm because a conflict I have."],
        ["role": "assistant", "content": #"{"corrected":"Can we move tomorrow's meeting to 3pm? I have a conflict."}"#],
        ["role": "user", "content": "I am writing this email for the purpose of asking whether it would be possible for you to send the report."],
        ["role": "assistant", "content": #"{"corrected":"Could you send me the report?"}"#],
        ["role": "user", "content": "Context for the other agent (the actual fix): this config is correct"],
        ["role": "assistant", "content": #"{"corrected":"Context for the other agent (the actual fix): this config is correct"}"#],
        // Casual chat: no capital, no full stop added — it's complete as written.
        ["role": "user", "content": "thanks"],
        ["role": "assistant", "content": #"{"corrected":"thanks"}"#],
        ["role": "user", "content": "on my way, be there in 5"],
        ["role": "assistant", "content": #"{"corrected":"on my way, be there in 5"}"#],
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
        // Bounded: one request per sentence, all at once, means a long field
        // fires dozens of concurrent completions at a single GPU. Measured on a
        // 12,000-character field: 22 requests in flight, every one of them
        // failing after 1.2s while the machine stuttered. A few at a time
        // finishes sooner and leaves the GPU to the compositor.
        let inFlight = 3
        var out: [SentenceCorrection] = []
        let started = DispatchTime.now()
        if sentences.count > inFlight {
            Log.debug(.llm, "checking a long field in batches",
                      ["sentences": sentences.count, "inFlight": inFlight])
        }
        var index = 0
        await withTaskGroup(of: SentenceCorrection?.self) { group in
            // Prime the group, then keep exactly `inFlight` running: as each
            // finishes, the next starts.
            while index < min(inFlight, sentences.count) {
                let sentence = sentences[index]
                group.addTask { await correctSentence(sentence) }
                index += 1
            }
            while let result = await group.next() {
                if let result { out.append(result) }
                if index < sentences.count {
                    let sentence = sentences[index]
                    group.addTask { await correctSentence(sentence) }
                    index += 1
                }
            }
        }
        if sentences.count > inFlight {
            Log.info(.llm, "long field checked", ["sentences": sentences.count,
                                                  "fixes": out.count,
                                                  "ms": Log.ms(since: started)])
        }
        return out
    }

    /// Correct one sentence in isolation, caching successful results. Returns nil
    /// if the model left it unchanged (or the request failed).
    private func correctSentence(_ sentence: String) async -> SentenceCorrection? {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return nil }

        if let cached = await GrammarCache.shared.get(trimmed) {
            Log.debug(.llm, "grammar cache hit", ["chars": trimmed.count,
                                                  "changed": cached != trimmed])
            return cached == trimmed ? nil : SentenceCorrection(original: trimmed, corrected: cached)
        }

        let req = Log.nextRequestID()
        let started = DispatchTime.now()
        Log.debug(.llm, "grammar request", ["req": req, "chars": trimmed.count,
                                            "port": chatURL.port ?? 0])

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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // A superseded check cancels its request; that is the system working,
            // not a failure, and logging it as one buries the real ones.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                Log.debug(.llm, "request cancelled, field moved on", ["req": req])
            } else {
                Log.warn(.llm, "request failed", ["req": req, "ms": Log.ms(since: started),
                                                  "port": chatURL.port ?? 0,
                                                  "error": error.localizedDescription])
            }
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Log.warn(.llm, "request rejected by the server", ["req": req, "status": status,
                                                        "ms": Log.ms(since: started)])
            return nil
        }
        guard
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

        // Sanity guard: some models (narrow fine-tunes on text they can't
        // handle, e.g. non-English) echo the prompt instructions back as the
        // "correction". Never surface those — treat the sentence as clean.
        guard isPlausibleCorrection(corrected, of: trimmed) else {
            Log.warn(.llm, "discarded implausible correction", [
                "req": req, "ms": Log.ms(since: started),
                "reason": "prompt echo or runaway length",
                "in": String(trimmed.prefix(60)), "out": String(corrected.prefix(60)),
            ])
            await GrammarCache.shared.set(trimmed, trimmed)
            return nil
        }

        // The model normalizes typography: straight quotes where the field uses
        // curly ones. Left alone, a sentence that differs only in that is flagged
        // as a change, and accepting it does nothing visible — or the app's own
        // smart-quote substitution undoes it. That is the "doesn't -> doesn't"
        // no-op. Match the model's punctuation back to the field's first.
        var normalized = Self.matchTypography(of: corrected, to: trimmed)
        // Put back any contraction the writer used but the model expanded
        // ("That's" -> "That is") — expanding them is exactly the formalising
        // they didn't ask for.
        normalized = Self.preserveContractions(of: normalized, to: trimmed)
        // Small models formalise casual chat — "thanks" -> "Thanks.", "on my
        // way" -> "On my way." — which is annoying, not a correction. If the
        // model's only change is a leading capital and/or an added terminal
        // stop, keep what the writer actually wrote. A change that also fixes a
        // real error survives (its remaining diff isn't just casing/punctuation).
        if Self.differsOnlyByCasingOrTerminalStop(normalized, from: trimmed) {
            normalized = trimmed
        }
        let changed = normalized != trimmed
        Log.info(.llm, changed ? "sentence rewritten" : "sentence already fine",
                 ["req": req, "ms": Log.ms(since: started), "chars": trimmed.count])
        if changed { Log.debug(.llm, "rewrite", ["req": req, "in": trimmed, "out": normalized]) }
        await GrammarCache.shared.set(trimmed, normalized)
        return changed ? SentenceCorrection(original: trimmed, corrected: normalized) : nil
    }

    /// Contractions the writer might use, and the expanded forms a model turns
    /// them into. Order matters only in that longer expansions are safe to run
    /// first; there's no overlap here.
    private static let contractions: [(short: String, long: String)] = [
        ("don't", "do not"), ("doesn't", "does not"), ("didn't", "did not"),
        ("isn't", "is not"), ("aren't", "are not"), ("wasn't", "was not"),
        ("weren't", "were not"), ("won't", "will not"), ("wouldn't", "would not"),
        ("couldn't", "could not"), ("shouldn't", "should not"), ("can't", "cannot"),
        ("can't", "can not"), ("haven't", "have not"), ("hasn't", "has not"),
        ("hadn't", "had not"), ("it's", "it is"), ("that's", "that is"),
        ("there's", "there is"), ("here's", "here is"), ("what's", "what is"),
        ("who's", "who is"), ("he's", "he is"), ("she's", "she is"),
        ("i'm", "i am"), ("you're", "you are"), ("we're", "we are"),
        ("they're", "they are"), ("i've", "i have"), ("you've", "you have"),
        ("we've", "we have"), ("they've", "they have"), ("i'll", "i will"),
        ("you'll", "you will"), ("we'll", "we will"), ("they'll", "they will"),
        ("let's", "let us"),
    ]

    /// Re-contract in `corrected` any expansion whose contraction the writer
    /// actually used in `original`, so a model can't quietly formalise the
    /// writer's own contractions. Only touches forms the writer already
    /// contracted — text they genuinely wrote expanded is left expanded.
    static func preserveContractions(of corrected: String, to original: String) -> String {
        let lowerOriginal = original.lowercased()
        var out = corrected
        for (short, long) in contractions where lowerOriginal.contains(short) {
            out = replacePreservingLeadingCase(long, with: short, in: out)
        }
        return out
    }

    /// Case-insensitive whole-word replace of `find` with `replacement`, keeping
    /// the case of the matched text's first letter (so "That is" -> "That's").
    private static func replacePreservingLeadingCase(_ find: String, with replacement: String,
                                                     in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b" + NSRegularExpression.escapedPattern(for: find) + "\\b",
            options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var result = text
        // Work right-to-left so ranges stay valid.
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let matched = ns.substring(with: m.range)
            let capitalised = matched.first?.isUppercase == true
            let rep = capitalised ? replacement.prefix(1).uppercased() + replacement.dropFirst()
                                  : replacement
            result = (result as NSString).replacingCharacters(in: m.range, with: rep)
        }
        return result
    }

    /// True when `corrected` differs from `original` only by capitalising the
    /// first letter and/or adding one trailing sentence-ending mark — the
    /// formalising a chat message doesn't ask for. Any other difference (a real
    /// spelling or grammar fix) makes this false, so genuine corrections pass.
    static func differsOnlyByCasingOrTerminalStop(_ corrected: String, from original: String) -> Bool {
        func canonical(_ s: String) -> String {
            var t = Substring(s)
            while let last = t.last, ".!?".contains(last) { t = t.dropLast() }
            let lowered = t.isEmpty ? t : t.first!.lowercased() + t.dropFirst()
            return String(lowered)
        }
        return corrected != original && canonical(corrected) == canonical(original)
    }

    /// Restore the field's own typography in the model's output. Models answer
    /// with straight quotes ('), straight double quotes, and hyphens; a field
    /// often uses curly quotes and dashes. Swapping them back keeps real edits
    /// while dropping the invisible ones the diff would otherwise flag — and
    /// stops the app's smart-quote substitution from undoing an accept. Only a
    /// character the field itself favours is ever introduced.
    static func matchTypography(of corrected: String, to original: String) -> String {
        var out = corrected
        let curlyApostrophe = "\u{2019}", curlyOpenSingle = "\u{2018}"
        let curlyOpenDouble = "\u{201C}", curlyCloseDouble = "\u{201D}"
        if original.contains(curlyApostrophe) {
            out = out.replacingOccurrences(of: "'", with: curlyApostrophe)
        }
        if original.contains(curlyOpenSingle) {
            out = out.replacingOccurrences(of: "`", with: curlyOpenSingle)
        }
        if original.contains(curlyOpenDouble) || original.contains(curlyCloseDouble) {
            // Models emit matched pairs of straight double quotes; alternate.
            var result = "", open = true
            for ch in out where true {
                if ch == "\"" {
                    result += open ? curlyOpenDouble : curlyCloseDouble
                    open.toggle()
                } else {
                    result.append(ch)
                }
            }
            out = result
        }
        return out
    }

    /// Generic prompt fragments that only appear when a model echoes our own
    /// instructions back; per-model markers come from the manifest.
    private static let genericEchoMarkers = [
        "You correct a single sentence",
        "\"corrected\" field",
        "'corrected' field",
    ]

    /// A grammar fix should resemble the input: reject outputs that quote our
    /// own prompt or balloon far beyond the original sentence.
    func isPlausibleCorrection(_ corrected: String, of original: String) -> Bool {
        for marker in Self.genericEchoMarkers + echoMarkers
        where corrected.contains(marker) { return false }
        let cap = max(Double(original.count) * maxGrowth, Double(original.count + 60))
        return Double(corrected.count) <= cap
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
