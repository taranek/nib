import AppKit
import ApplicationServices

/// Per-app placement and behavior tweaks, keyed by bundle id — one home for the
/// "Slack reports X a little wrong, Gmail does Y" corrections instead of
/// special cases scattered through the controller. An app without an entry gets
/// the neutral adapter (all zeros), so adding one is purely additive.
struct AppAdapter {
    /// Vertical nudge for the selection pill, in screen points; positive moves
    /// the pill DOWN. For apps whose selection geometry (marker bounds) sits a
    /// touch high of where the text actually renders.
    var pillNudge: CGFloat = 0
}

enum AppAdapters {
    private static let table: [String: AppAdapter] = [
        // Slack's marker-bounds answers sit slightly above the composer's text;
        // without the nudge the pill floats above the input line.
        "com.tinyspeck.slackmacgap": AppAdapter(pillNudge: 4),
    ]

    static func adapter(forBundleID id: String?) -> AppAdapter {
        id.flatMap { table[$0] } ?? AppAdapter()
    }

    /// Adapter for the app owning `element` (pid lookup is local, no AX IPC).
    static func adapter(for element: AXUIElement) -> AppAdapter {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        else { return AppAdapter() }
        return adapter(forBundleID: bundle)
    }
}
