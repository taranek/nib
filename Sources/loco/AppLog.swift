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

    static func bootstrap() {
        let fm = FileManager.default
        try? fm.createDirectory(at: LLMPaths.logsDir, withIntermediateDirectories: true)

        // Keep it from growing without bound: start fresh past ~1 MB.
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 1_000_000 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
        }

        let launchedByFinder = getppid() == 1
        if launchedByFinder {
            freopen(url.path, "a", stdout)
            freopen(url.path, "a", stderr)
            setbuf(stdout, nil)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let banner = "━━ Nib \(version) launched \(stamp) (pid \(getpid()), \(launchedByFinder ? "Finder" : "terminal"))\n"
        if launchedByFinder {
            print(banner, terminator: "")
        } else if let handle = try? FileHandle(forWritingTo: url) {
            // Terminal launches keep console output; still record the launch.
            handle.seekToEndOfFile()
            handle.write(Data(banner.utf8))
            try? handle.close()
        }
    }
}
