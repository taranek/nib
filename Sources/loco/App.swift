import Cocoa

// MARK: - Entry point

@main
@MainActor
struct Loco {
    static func main() {
        setbuf(stdout, nil) // unbuffered: logs show even when piped
        AppLog.bootstrap()  // banner + Finder-launch stdout/stderr → nib.log

        let app = NSApplication.shared
        // Accessory: no Dock icon, no menu bar — it's a background overlay agent.
        app.setActivationPolicy(.accessory)

        let controller = AppController()
        // Delegate handles Dock-icon clicks (the icon shows while the
        // settings/onboarding panel is open) to resurface a buried panel.
        app.delegate = controller
        controller.start()

        app.run()
    }
}
