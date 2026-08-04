import Cocoa

/// Floating performance HUD — a general debugging utility (toggled from the
/// status item's right-click menu, or forced on with LOCO_PERF=1). While
/// measuring, every sample is also appended to logs/perf.log for offline
/// analysis (same folder Settings → Logs opens).
///
/// Metrics:
///  - FPS / stall: a 120Hz main-run-loop timer counts fires; missed fires mean
///    the main thread was busy. `stall` is the longest gap seen in the window —
///    the number that IS "the UI felt laggy".
///  - CPU / RAM of this process.
///  - Per-server llama health-ping latency (GPU saturation shows up here first).
///  - Last grammar-check round trip, reported by the controller.
@MainActor
final class PerfHUD {
    static let shared = PerfHUD()

    /// Provider wired by the controller: [(label, port)] for live servers.
    var serversProvider: () -> [(String, Int)] = { [] }
    /// Last end-to-end grammar check duration, reported by the controller.
    var lastGrammarMs: Int?

    private var panel: FloatingPanel?
    private var label: NSTextField?

    private var frameTimer: Timer?
    private var updateTimer: Timer?
    private var frames = 0
    private var lastFire = CFAbsoluteTimeGetCurrent()
    private var windowStart = CFAbsoluteTimeGetCurrent()
    private var maxStall: Double = 0
    private var lastCPUTime: Double = 0
    private var lastCPUStamp = CFAbsoluteTimeGetCurrent()
    private var pings: [Int: Int] = [:]   // port → ms
    private var lastCPU: Double = 0
    private var lastRAM: Double = 0

    var visible: Bool { panel?.isVisible == true }

    func toggle() { visible ? hide() : show() }

    func show() {
        if panel == nil { build() }
        windowStart = CFAbsoluteTimeGetCurrent()
        lastFire = windowStart
        frames = 0
        maxStall = 0
        panel?.orderFrontRegardless()

        // Frame counter: 120Hz in .common so it keeps firing during tracking.
        let frame = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFrame() }
        }
        RunLoop.main.add(frame, forMode: .common)
        frameTimer = frame

        let update = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(update, forMode: .common)
        updateTimer = update
    }

    func hide() {
        panel?.orderOut(nil)
        frameTimer?.invalidate(); frameTimer = nil
        updateTimer?.invalidate(); updateTimer = nil
    }

    private func tickFrame() {
        let now = CFAbsoluteTimeGetCurrent()
        maxStall = max(maxStall, now - lastFire)
        lastFire = now
        frames += 1
    }

    private func refresh() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - windowStart
        let fps = elapsed > 0 ? min(120, Int(Double(frames) / elapsed)) : 0
        let stallMs = Int(maxStall * 1000)
        frames = 0
        windowStart = now
        maxStall = 0

        lastCPU = cpuPercent()
        lastRAM = ramMB()
        var lines = [
            String(format: "fps %3d   stall %4dms", fps, stallMs),
            String(format: "cpu %3.0f%%  ram %5.0fMB", lastCPU, lastRAM),
        ]
        for (name, port) in serversProvider() {
            let ping = pings[port].map { "\($0)ms" } ?? "…"
            lines.append("\(name.padding(toLength: 10, withPad: " ", startingAt: 0)) :\(port) \(ping)")
            pingServer(port: port)
        }
        if let ms = lastGrammarMs { lines.append("last check \(ms)ms") }
        label?.stringValue = lines.joined(separator: "\n")
        logSample(fps: fps, stallMs: stallMs)
    }

    // MARK: - File log

    private static var logURL: URL { LLMPaths.logsDir.appendingPathComponent("perf.log") }
    private lazy var stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f
    }()

    /// One compact line per sample; starts fresh past ~2 MB.
    private func logSample(fps: Int, stallMs: Int) {
        let fm = FileManager.default
        try? fm.createDirectory(at: LLMPaths.logsDir, withIntermediateDirectories: true)
        if let size = try? fm.attributesOfItem(atPath: Self.logURL.path)[.size] as? Int,
           size > 2_000_000 {
            try? fm.removeItem(at: Self.logURL)
        }
        let servers = serversProvider()
            .map { "\($0.0):\(pings[$0.1].map(String.init) ?? "-")ms" }
            .joined(separator: " ")
        let check = lastGrammarMs.map { "\($0)ms" } ?? "-"
        let line = String(
            format: "%@ fps=%d stall=%dms cpu=%.0f%% ram=%.0fMB %@ check=%@\n",
            stamp.string(from: Date()), fps, stallMs, lastCPU, lastRAM, servers, check)
        if !fm.fileExists(atPath: Self.logURL.path) {
            fm.createFile(atPath: Self.logURL.path, contents: Data())
        }
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    /// Time a /health round trip per server — inference queuing shows up here.
    private func pingServer(port: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let start = CFAbsoluteTimeGetCurrent()
        URLSession.shared.dataTask(with: request) { _, _, _ in
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PerfHUD.shared.pings[port] = ms }
            }
        }.resume()
    }

    private func cpuPercent() -> Double {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return 0 }
        let total = Double(usage.ri_user_time + usage.ri_system_time) / 1e9
        let now = CFAbsoluteTimeGetCurrent()
        let percent = (total - lastCPUTime) / max(now - lastCPUStamp, 0.001) * 100
        lastCPUTime = total
        lastCPUStamp = now
        return max(0, percent)
    }

    private func ramMB() -> Double {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return 0 }
        return Double(usage.ri_phys_footprint) / 1_048_576
    }

    private func build() {
        let width: CGFloat = 230
        let height: CGFloat = 110
        let panel = FloatingPanel(size: NSSize(width: width, height: height))
        panel.hasShadow = true

        let box = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        box.material = .hudWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 8

        let text = NSTextField(labelWithString: "…")
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .labelColor
        text.frame = NSRect(x: 10, y: 8, width: width - 20, height: height - 16)
        text.maximumNumberOfLines = 0
        text.cell?.truncatesLastVisibleLine = true
        box.addSubview(text)

        panel.contentView = box
        // Top-right corner of the main screen, under the menu bar.
        if let vis = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vis.maxX - width - 12,
                                         y: vis.maxY - height - 12))
        }
        self.panel = panel
        self.label = text
    }
}
