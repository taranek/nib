import Foundation

/// One log file for everything Nib does: user actions, detection passes, LLM
/// calls and the model server's own output, in the order they happened.
///
/// A line looks like:
///
///     14:32:07.412  INFO   llm       sentence rewritten   chars=42 ms=812 req=17
///
/// Fixed columns so a category can be scanned down the page, `key=value` fields
/// so `grep` and `awk` can pull numbers out. Anything that took time carries
/// `ms=`; every model request carries `req=` so a call and its result can be
/// matched even when several are in flight.
///
/// Tuned by environment variable, both optional:
///
///     LOCO_LOG_LEVEL=debug|info|warn|error   (default info; LOCO_DEBUG implies debug)
///     LOCO_LOG=llm,detect                    (only these categories; default all)
enum Log {
    enum Level: Int, Comparable {
        case debug = 0, info, warn, error
        var name: String { ["DEBUG", "INFO", "WARN", "ERROR"][rawValue] }
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Coarse areas, chosen so filtering by one answers a real question: "what
    /// did the model do", "why is nothing detected", "what did the user do".
    enum Category: String, CaseIterable {
        case app        // lifecycle: launch, quit, permissions, updates
        case action     // what the user did: card opened, fix accepted, app blocked
        case detect     // focus, checks, corrections, highlights
        case llm        // requests to a model and what came back
        case server     // llama-server lifecycle
        case llama      // the model server's own output
        case ax         // accessibility oddities worth knowing about
        case browser    // the page bridge
        case ui         // panels, pill, overlay
    }

    // MARK: - Filtering

    private static let threshold: Level = {
        switch ProcessInfo.processInfo.environment["LOCO_LOG_LEVEL"]?.lowercased() {
        case "debug": return .debug
        case "info": return .info
        case "warn": return .warn
        case "error": return .error
        default:
            return ProcessInfo.processInfo.environment["LOCO_DEBUG"] != nil ? .debug : .info
        }
    }()

    /// Empty means every category; otherwise only the ones named.
    private static let only: Set<Category> = {
        guard let raw = ProcessInfo.processInfo.environment["LOCO_LOG"] else { return [] }
        return Set(raw.split(separator: ",").compactMap { Category(rawValue: String($0).trimmed) })
    }()

    private static func passes(_ level: Level, _ category: Category) -> Bool {
        level >= threshold && (only.isEmpty || only.contains(category))
    }

    // MARK: - Writing

    static func debug(_ c: Category, _ m: String, _ f: [String: Any] = [:]) { write(.debug, c, m, f) }
    static func info(_ c: Category, _ m: String, _ f: [String: Any] = [:]) { write(.info, c, m, f) }
    static func warn(_ c: Category, _ m: String, _ f: [String: Any] = [:]) { write(.warn, c, m, f) }
    static func error(_ c: Category, _ m: String, _ f: [String: Any] = [:]) { write(.error, c, m, f) }

    /// Passthrough for another process's output: already formatted, so it keeps
    /// its own shape and only gains a timestamp and a category.
    static func raw(_ c: Category, _ text: String) {
        guard passes(.debug, c) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            emit(line: "\(stamp())  \(pad("DEBUG", 6)) \(pad(c.rawValue, 9)) \(line)\n")
        }
    }

    // MARK: - Scopes

    /// A logger bound to a category and a set of fields every line repeats —
    /// the request id on a model call, the app name on a detection pass — so
    /// callers don't restate them and can't forget to.
    struct Scope {
        let category: Category
        let fields: [String: Any]
        private let started = DispatchTime.now()

        func debug(_ m: String, _ f: [String: Any] = [:]) { Log.write(.debug, category, m, merged(f)) }
        func info(_ m: String, _ f: [String: Any] = [:]) { Log.write(.info, category, m, merged(f)) }
        func warn(_ m: String, _ f: [String: Any] = [:]) { Log.write(.warn, category, m, merged(f)) }
        func error(_ m: String, _ f: [String: Any] = [:]) { Log.write(.error, category, m, merged(f)) }

        /// Same, plus how long it has been since the scope was made — the usual
        /// shape for "started X" … "finished X".
        func done(_ m: String, _ f: [String: Any] = [:]) {
            Log.write(.info, category, m, merged(f).merging(["ms": Log.ms(since: started)]) { _, b in b })
        }

        /// Narrow an existing scope further, keeping its fields.
        func scope(_ f: [String: Any]) -> Scope { Scope(category: category, fields: merged(f)) }

        private func merged(_ f: [String: Any]) -> [String: Any] {
            fields.merging(f) { _, new in new }
        }
    }

    static func scope(_ c: Category, _ f: [String: Any] = [:]) -> Scope {
        Scope(category: c, fields: f)
    }

    /// An id to tie a request to its result in a file where several are in
    /// flight at once.
    static func nextRequestID() -> Int { counter.next() }
    private static let counter = Counter()

    /// Milliseconds since `start`, for callers that can't wrap a block.
    static func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    // MARK: - Formatting and the file

    fileprivate static func write(_ level: Level, _ category: Category, _ message: String,
                                  _ fields: [String: Any]) {
        guard passes(level, category) else { return }
        let rendered = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(format($0.value))" }
            .joined(separator: " ")
        let tail = rendered.isEmpty ? "" : "  \(rendered)"
        emit(line: "\(stamp())  \(pad(level.name, 6)) \(pad(category.rawValue, 9)) \(message)\(tail)\n")
    }

    /// Serial: the order in the file is the order of events, and the file is
    /// opened once rather than per line.
    private static let queue = DispatchQueue(label: "com.nib.log", qos: .utility)
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var written = 0

    private static func emit(line: String) {
        let data = Data(line.utf8)
        queue.async {
            if handle == nil { open() }
            handle?.write(data)
            written += data.count
            if written > maxFileSize { rotate() }
        }
        // A terminal run keeps its console; a Finder run has none to keep.
        if !AppLog.launchedDetached { FileHandle.standardError.write(data) }
    }

    private static let maxFileSize = 4_000_000
    private static let keptFiles = 3

    /// Wall-clock time of day, because bug reports are phrased in it.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static func stamp() -> String { clock.string(from: Date()) }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    /// Quote anything containing spaces so `key=value` stays parseable, and
    /// render doubles readably rather than as 0.30000000000000004.
    private static func format(_ value: Any) -> String {
        switch value {
        case let d as Double: return String(format: "%.2f", d)
        case let s as String:
            let clean = s.replacingOccurrences(of: "\n", with: "\\n")
            return clean.contains(" ") ? "\"\(clean.replacingOccurrences(of: "\"", with: "'"))\"" : clean
        default: return "\(value)"
        }
    }

    private static func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: LLMPaths.logsDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: AppLog.url.path) {
            fm.createFile(atPath: AppLog.url.path, contents: Data())
        }
        handle = try? FileHandle(forWritingTo: AppLog.url)
        handle?.seekToEndOfFile()
        written = (try? fm.attributesOfItem(atPath: AppLog.url.path)[.size] as? Int).flatMap { $0 } ?? 0
    }

    /// Keep a few previous files: an investigation usually starts after the
    /// run that went wrong has already ended.
    private static func rotate() {
        try? handle?.close()
        handle = nil
        written = 0
        let fm = FileManager.default
        let dir = AppLog.url.deletingLastPathComponent()
        func archive(_ n: Int) -> URL { dir.appendingPathComponent("nib.log.\(n)") }
        try? fm.removeItem(at: archive(keptFiles))
        for n in stride(from: keptFiles - 1, through: 1, by: -1) {
            try? fm.moveItem(at: archive(n), to: archive(n + 1))
        }
        try? fm.moveItem(at: AppLog.url, to: archive(1))
        open()
    }
}

/// Request ids are handed out from several queues.
private final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
