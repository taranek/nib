import Darwin
import Foundation

/// Always-on, low-cost performance sampling into the main log, so "Nib makes my
/// machine feel slow" can be answered from a file instead of a hunch.
///
/// A sample looks like:
///
///     22:41:07.004  INFO   perf      sample  cpu=1.4 ramMB=96 stallMs=18 servers=2 serverRamGB=8.4 serverCPU=0.2
///
/// The two numbers that usually matter are `stallMs` — the longest the main
/// thread went unresponsive, which is what a user feels as lag — and
/// `serverRamGB`, because a resident model is far larger than the app itself
/// and is the most likely reason the rest of the machine started swapping.
@MainActor
final class PerfMonitor {
    static let shared = PerfMonitor()

    /// How often a sample is written. Long, because the point is a trend across
    /// a working day, not a profiler.
    private let interval: TimeInterval = 60
    /// The watchdog fires far more often than it samples: a stall is only
    /// visible if something is trying to run while the main thread is blocked.
    private let watchdogInterval: TimeInterval = 0.1

    private var sampler: Timer?
    private var watchdog: Timer?
    private var lastBeat = CFAbsoluteTimeGetCurrent()
    private var worstStall: TimeInterval = 0
    private var lastCPUTime: Double = 0
    private var lastCPUStamp = CFAbsoluteTimeGetCurrent()

    func start() {
        guard sampler == nil else { return }
        _ = cpuPercent()   // prime the delta, so the first sample isn't since-launch

        // .common so the samples keep coming while a menu or a drag has the
        // run loop in another mode — exactly when stalls are worth catching.
        let beat = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                // Anything beyond the interval is time the main thread owed us.
                let late = now - self.lastBeat - self.watchdogInterval
                if late > self.worstStall { self.worstStall = late }
                self.lastBeat = now
            }
        }
        RunLoop.main.add(beat, forMode: .common)
        watchdog = beat

        let sample = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(sample, forMode: .common)
        sampler = sample

        // A baseline early on, so even a short session leaves one line saying
        // what the app was costing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated { self?.sample("baseline") }
        }
    }

    func stop() {
        sampler?.invalidate(); sampler = nil
        watchdog?.invalidate(); watchdog = nil
    }

    /// Written on every sample, and on demand when something notable happened.
    func sample(_ note: String = "sample") {
        let servers = modelServers()
        var fields: [String: Any] = [
            "cpu": cpuPercent(),
            "ramMB": Int(ramMB()),
            "stallMs": Int(worstStall * 1000),
            "servers": servers.count,
        ]
        if !servers.isEmpty {
            fields["serverRamGB"] = (servers.reduce(0) { $0 + $1.ramMB } / 1024).rounded(to: 1)
            fields["serverCPU"] = servers.reduce(0) { $0 + $1.cpu }.rounded(to: 1)
        }
        // A stall the user would actually have felt is worth finding on its own.
        let level: Log.Level = worstStall > 0.25 ? .warn : .info
        if level == .warn {
            Log.warn(.perf, "main thread stalled", fields)
        } else {
            Log.info(.perf, note, fields)
        }
        worstStall = 0
    }

    // MARK: - Measuring

    /// Our own CPU share since the previous sample.
    private func cpuPercent() -> Double {
        var usage = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        } == 0
        guard ok else { return 0 }
        let total = Double(usage.ri_user_time + usage.ri_system_time) / 1e9
        let now = CFAbsoluteTimeGetCurrent()
        let percent = (total - lastCPUTime) / max(now - lastCPUStamp, 0.001) * 100
        lastCPUTime = total
        lastCPUStamp = now
        return max(0, percent).rounded(to: 1)
    }

    private func ramMB() -> Double {
        var usage = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        } == 0
        return ok ? Double(usage.ri_phys_footprint) / 1_048_576 : 0
    }

    /// The model servers, which are the app's real weight: the app measures in
    /// megabytes, a resident model in gigabytes. Read from `ps` rather than
    /// tracked internally so a server orphaned by a previous run still counts —
    /// it's still on the user's machine.
    private func modelServers() -> [(ramMB: Double, cpu: Double)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "rss=,%cpu=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard line.contains("llama-server") else { return nil }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let rss = Double(parts[0]), let cpu = Double(parts[1])
            else { return nil }
            return (rss / 1024, cpu)
        }
    }
}

private extension Double {
    func rounded(to places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (self * f).rounded() / f
    }
}
