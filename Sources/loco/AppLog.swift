import Foundation

/// App-level file logging. Every launch appends a banner to
/// Application Support/Nib/logs/nib.log, and when the app is launched without
/// a terminal (Finder/`open`, parent is launchd) stdout + stderr are pointed
/// at the log too — so every print() is diagnosable in the field.
///
/// Diagnostic note: a launch that leaves NO banner never reached main() at
/// all (e.g. wedged in dyld by a Gatekeeper assessment).
enum AppLog {
    static var url: URL { LLMPaths.logsDir.appendingPathComponent("nib.log") }

    /// Launched with no terminal attached (Finder/`open`, parent is launchd),
    /// so there is no console for Log to mirror to.
    static let launchedDetached = getppid() == 1

    static func bootstrap() {
        let fm = FileManager.default
        try? fm.createDirectory(at: LLMPaths.logsDir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
        }

        // Anything that still uses print() (and anything AppKit writes to
        // stderr) lands in the same file as Log, in order.
        if launchedDetached {
            freopen(url.path, "a", stdout)
            freopen(url.path, "a", stderr)
            setvbuf(stdout, nil, _IOLBF, 4096)   // line buffered, not unbuffered
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
        // A dated separator per launch: the file spans runs, and "which run was
        // this?" is the first question when reading one.
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let banner = "\n━━━ Nib \(version) — \(day.string(from: Date())) — pid \(getpid())"
            + " — \(launchedDetached ? "launched by Finder" : "launched from a terminal") ━━━\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(banner.utf8))
            try? handle.close()
        }
    }
}
