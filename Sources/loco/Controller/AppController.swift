import Cocoa
import ApplicationServices
import NaturalLanguage
import Carbon.HIToolbox
import UniformTypeIdentifiers
import WebKit

// MARK: - Controller
//
// Wires everything together: watches the focused field, runs grammar checks
// through the local LLM (debounced + async), maps each flagged phrase to an
// on-screen rect, draws highlights, and drives the hover card + settings popover.

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow!
    private var view: OverlayView!
    private var popoverPanel: PopoverPanel!
    private var pillPanel: PillPanel!
    private let browser = BrowserBridge()
    static let debug = ProcessInfo.processInfo.environment["LOCO_DEBUG"] != nil
    private var timer: Timer?
    private var mouseMonitor: Any?

    // Menu bar presence + the settings popover it opens.
    private var statusItem: NSStatusItem?
    private var settingsPopover: SettingsPopover?
    // Last Accessibility-trust value pushed to settings, so we re-push live when
    // the user grants/revokes it while the panel is open.
    private var lastSettingsTrusted: Bool?
    private var enabled = true
    // Default target language for the Translate tab (persisted).
    private var targetLanguage = UserDefaults.standard.string(forKey: "targetLanguage") ?? "English"
    /// Show the per-change rule explainers under grammar fixes (Settings toggle).
    private var explainFixes = UserDefaults.standard.object(forKey: "explainFixes") as? Bool ?? true
    /// After Harper's instant rule pass, also run the LLM in the background to
    /// catch sense-level errors rules can't see (Settings toggle, default off).
    private var deepCheck = UserDefaults.standard.object(forKey: "deepCheck") as? Bool ?? false
    /// Apps the user has switched Nib off for: bundle ID → display name.
    private var blockedApps: [String: String] =
        UserDefaults.standard.dictionary(forKey: "blockedApps") as? [String: String] ?? [:]
    /// Last app that wasn't us — what the status-item menu offers to block, since
    /// opening that menu can make us frontmost.
    private var lastActiveApp: (id: String, name: String)?

    // The field + flagged words the UI currently targets.
    private var activeElement: AXUIElement?
    private var activeBrowserAppName: String?
    private var flagged: [FlaggedWord] = []

    // The word whose card is open, and the word the cursor is currently over.
    private var activeWord: FlaggedWord?
    private var hoveredID: String?
    private var hideHoverTimer: Timer?
    // Auto-close a popover the user opened but never moved onto.
    private var autoDismissTimer: Timer?
    private let autoDismissDelay: TimeInterval = 1.5

    // Rephrase: a pill near the current selection; hover it for a proposal.
    private enum PopoverMode { case none, grammar, rephrase }
    private var popoverMode: PopoverMode = .none
    private var pillRect: CGRect?
    private var pillDwell: Timer?                // hover-to-open delay
    /// Last believable pill anchor, kept per focused element (see below).
    private var lastAnchor: (element: AXUIElement, rect: CGRect)?
    private var retriedAnchor = false            // one retry per failed anchor
    /// When the user last typed. The pill waits for a pause: a marker that
    /// appears and hops line to line mid-sentence is a distraction, and every
    /// move of it costs an AX geometry round-trip.
    /// `AX.isInWebArea` walks ancestors with two AX round-trips per level, and
    /// the answer can't change without the focus changing — so it's asked once
    /// per element rather than twice per tick.
    private var cachedWebArea: (element: AXUIElement, isWeb: Bool)?
    /// A grammar check is actually running — the only time the pill animates.
    private var isChecking = false {
        didSet { if isChecking != oldValue { refreshPillState() } }
    }
    private var signalSources: [DispatchSourceSignal] = []
    private var lastTypedAt = Date.distantPast
    private let typingQuiet: TimeInterval = 0.6
    /// Whether the pill currently marks a selection (vs. just the caret).
    private var pillOnSelection = false
    private var rephraseText: String?            // selection text the pill acts on
    private var rephraseAppName: String?
    private var rephraseElement: AXUIElement?
    private var rephraseRange: NSRange?          // native write-back range
    private var selectionDebounce: Timer?
    private var rephraseHotKey: GlobalHotKey?     // global shortcut → rephrase

    // Onboarding sandbox: while true, the selection pill + ⌘` card deliberately
    // target our own onboarding textarea (they normally ignore our own windows),
    // letting the user try the real card without leaving the flow.
    private var sandboxActive = false

    // In-flight catalog-model download (one at a time).
    private var modelDownload: URLSessionDownloadTask?
    private var modelDownloadProgress: NSKeyValueObservation?

    // Per-task model routing: each task can be pinned to a downloaded catalog
    // model (UserDefaults "taskModel.<task>" = catalog id; absent = the default
    // model). Distinct pinned models get their own llama-server, spawned lazily
    // and kept warm.
    enum LLMTask: String, CaseIterable {
        case grammar, compose, translate
    }
    private var taskServers: [String: LLMServer] = [:]   // model path → server
    private var nextTaskPort = 18085

    // The card opens against a target; React fetches rewrites and sends back the
    // accepted text, which we write into this target.
    private var rewriteTarget: RewriteTarget?

    private struct RewriteTarget {
        let original: String         // text the accepted result replaces
        let appName: String?         // browser app (DOM write-back) or nil (native)
        let element: AXUIElement?    // native focused element
        let range: NSRange?          // native write-back range
    }

    // Words the user dismissed (by id) — cleared whenever the text changes,
    // since edits shift occurrence indices.
    private var dismissed = Set<String>()

    // Cache so we only re-evaluate when the text/frame changes.
    private var lastSignature: String = ""
    private var lastValueHash: Int = 0
    private var lastHighlightsKey: String = ""   // skip redundant overlay redraws

    // Local LLM grammar checking.
    private let llmServer = LLMServer()
    // Rule-based fast path: Harper (WASM) lints English instantly on CPU, so
    // the always-on squiggle pipeline doesn't touch the GPU; the LLM remains
    // the path for other languages and for the rewrite card.
    private var linterHost: LinterHost!
    private var llmClient: LLMClient?
    private var llmReady = false
    private var currentCorrections: [SentenceCorrection] = []
    private var currentFullText: String = ""
    private var checkedValueHash: Int = 0
    private var grammarDebounce: Timer?
    private var grammarTask: Task<Void, Never>?

    // PIDs we've already force-enabled accessibility on (Chromium/Electron
    // build their AX tree lazily and only for an attached AT — we have to ask).
    private var a11yEnabledPids = Set<pid_t>()

    private let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",   // Arc
        "com.operasoftware.Opera",
        "org.mozilla.firefox",
        "com.apple.Safari",
        // Electron apps benefit from the same switch:
        "com.microsoft.VSCode",
        "com.tinyspeck.slackmacgap",
        "notion.id",
    ]

    func start() {
        print("▸ controller starting (accessibility trusted: \(AXIsProcessTrusted()))")
        if !ensureAccessibilityPermission() {
            print("""
            ⏳ Accessibility permission required.
               1. Open System Settings → Privacy & Security → Accessibility
               2. Enable the entry for this binary (or your terminal app)
               3. Re-run:  swift run loco
            """)
        }

        // Span every display, not just the primary one: highlight rects are in
        // global screen coords, and anything outside this window is clipped.
        let desktop = Self.desktopFrame()
        window = OverlayWindow(screenFrame: desktop)
        view = OverlayView(frame: NSRect(origin: .zero, size: desktop.size))
        window.contentView = view
        window.orderFrontRegardless()

        popoverPanel = PopoverPanel(url: Self.webURL())
        popoverPanel.onEnter = { [weak self] in self?.cancelHidePopover() }
        popoverPanel.onExit = { [weak self] in self?.scheduleHidePopover() }
        popoverPanel.onMessage = { [weak self] body in self?.handleWebMessage(body) }

        // The selection pill: a tiny web surface with native hover/click.
        pillPanel = PillPanel(url: Self.webURL())
        pillPanel.onEnter = { [weak self] in
            guard let self else { return }
            cancelHidePopover()
            startPillDwell()
        }
        pillPanel.onExit = { [weak self] in
            self?.cancelPillDwell()
            self?.scheduleHidePopover()
        }
        pillPanel.onClick = { [weak self] in
            guard let self else { return }
            cancelPillDwell()   // a click opens right away
            if popoverMode != .rephrase { showRephrase() }
        }

        setupStatusItem()
        print("▸ status item installed")

        // Rule-based linter (offscreen webview) — ready a moment after launch.
        linterHost = LinterHost(url: Self.webURL())

        // Pre-create the settings popover so its web UI preloads before the first
        // open (otherwise the panel shows empty on launch).
        let popover = SettingsPopover(url: Self.webURL())
        popover.onMessage = { [weak self] body in self?.handleSettingsMessage(body) }
        settingsPopover = popover

        startLLM()

        // Reclaim task servers orphaned by a crashed/killed previous session
        // (the main port reclaims itself at spawn; 18085+ would leak).
        let reap = Process()
        reap.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        reap.arguments = ["-9", "-f", "llama-server.*--port 1808[5-9]"]
        try? reap.run()

        // Idle sweep: drop task-pinned models that haven't been used in 10 min.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapIdleTaskServers() }
        }

        // Perf HUD (right-click the menu-bar icon, or LOCO_PERF=1): live FPS/
        // stall, CPU/RAM, and per-server llama latency.
        PerfHUD.shared.serversProvider = { [weak self] in
            guard let self else { return [] }
            var servers = [(LLMPaths.modelName().map { String($0.prefix(10)) } ?? "default", llmServer.port)]
            for (path, server) in taskServers {
                servers.append((String(URL(fileURLWithPath: path).lastPathComponent.prefix(10)), server.port))
            }
            return servers
        }
        if ProcessInfo.processInfo.environment["LOCO_PERF"] != nil {
            PerfHUD.shared.show()
        }

        print("✅ Nib running. Grammar checked by a local LLM; hover a highlight to apply a fix.")
        print("   Card UI from: \(Self.webURL().absoluteString)\n")

        // Hover detection over the click-through overlay: a global mouse monitor
        // (fires for other apps; our accessory app is never frontmost) checks the
        // cursor against the flagged-word rects without consuming the events.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseMove() }
        }

        rememberActiveApp(NSWorkspace.shared.frontmostApplication)
        installSignalHandlers()
        registerRephraseHotKey()

        // Event-driven: react to focus/value changes via AXObserver, and to app
        // switches via NSWorkspace. A slow safety poll backstops anything not
        // delivered as a notification (e.g. scroll, window moves).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fitOverlayToDesktop() }
            }
        rebuildObservers()

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        // First-run onboarding: until the user has completed onboarding once, open
        // it on launch so they're guided through setup. Deferred so the status-item
        // button has a window (for positioning) and the web has loaded.
        if !LLMPaths.onboardingCompleted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.openSettings()
            }
        }
    }

    // MARK: - LLM lifecycle

    private func startLLM() {
        llmServer.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.llmReady = (status == .ready)
            if self.llmReady { self.llmClient = LLMClient(chatURL: self.llmServer.chatURL) }
            self.pushSettingsState()
            if self.llmReady {
                self.lastSignature = ""
                self.checkedValueHash = 0
                self.tick()
            }
        }
        llmServer.start()
    }

    private func llmStatusString() -> String {
        switch llmServer.status {
        case .stopped: return "Stopped"
        case .starting: return "Loading model…"
        case .ready: return "Ready"
        case .failed(let message): return "Error: \(message)"
        }
    }

    // MARK: - AX observers (event-driven updates)

    private var axObserver: AXObserver?
    private var observedElement: AXUIElement?

    @objc private func activeAppChanged() {
        // The selection pill belongs to the app we're leaving — the overlay is
        // global (above all apps), so drop it before re-evaluating the new app.
        hidePill()
        // Flip Chromium/Electron's AX switch as soon as the app comes to front —
        // before the switch, such apps may expose no focused element at all.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            enableBrowserAccessibility(pid: pid)
        }
        rebuildObservers()
        tick()
    }

    /// (Re)create the AXObserver for the frontmost app and observe focus changes.
    private func rebuildObservers() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        observedElement = nil

        // Never observe our own process: when Nib is frontmost (onboarding
        // sandbox), self-AX queries into our WKWebViews are brokered through our
        // own main thread — every focus change (e.g. arrow keys in the card)
        // stalls until the AX timeout, freezing the UI.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }

        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let controller = Unmanaged<AppController>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { controller.handleAXNotification(notification as String) }
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        axObserver = observer

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, appElement,
                                  kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        attachToFocusedElement()
    }

    /// Observe value + selection changes on the currently focused element.
    private func attachToFocusedElement() {
        guard let observer = axObserver else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let old = observedElement {
            AXObserverRemoveNotification(observer, old, kAXValueChangedNotification as CFString)
            AXObserverRemoveNotification(observer, old, kAXSelectedTextChangedNotification as CFString)
        }
        lastAnchor = nil   // a new field's geometry has nothing to do with the old
        retriedAnchor = false
        cachedWebArea = nil
        observedElement = AX.focusedElement()
        if let element = observedElement {
            AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
            AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, refcon)
        }
    }

    private func handleAXNotification(_ notification: String) {
        if notification == kAXFocusedUIElementChangedNotification as String {
            attachToFocusedElement()
            // The pill sits at the caret, so a newly focused field needs one
            // even when no selection-changed notification follows (Chromium
            // often doesn't send one on focus).
            scheduleSelectionUpdate()
        }
        if notification == kAXSelectedTextChangedNotification as String {
            scheduleSelectionUpdate()
        }
        if notification == kAXValueChangedNotification as String {
            lastTypedAt = Date()
            // Don't yank a card the user is working with — only the bare pill.
            if popoverMode == .none { hidePill() }
            scheduleSelectionUpdate(after: typingQuiet)
        }
        tick()
    }

    private func ensureAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Detection

    /// One pass: find focus, decide whether the text needs a fresh grammar check
    /// or just a re-locate of cached corrections. The heavy LLM call is debounced.
    private func tick() {
        // Remember where the user is working. Tracking this only on activation
        // notifications leaves it empty until they switch apps, which is exactly
        // when the menu's "Turn off for …" item goes missing.
        rememberActiveApp(NSWorkspace.shared.frontmostApplication)

        guard enabled else { return }

        // A card is open (and key, for hover) — its webview is the focused UI
        // element, so detection would see "focus left the field" and clear it.
        // Leave everything as-is until the card is dismissed.
        if popoverMode != .none { return }

        // Skip detection while our own UI is in front — nothing to correct there,
        // and not redrawing the full-screen overlay keeps the popover smooth.
        if settingsPopover?.isShown == true {
            // Keep the settings/onboarding state live while it's up — the user may
            // have just granted Accessibility (or chosen a model), which lets
            // onboarding advance to its "all set" screen. Onboarding closes only
            // when the user taps Done (handled in closeSettings).
            if AXIsProcessTrusted() != lastSettingsTrusted {
                pushSettingsState()
            }
            clearIfNeeded()
            return
        }
        if isBlockedApp() {
            clearIfNeeded()
            return
        }
        if frontmostIsSelf() {
            clearIfNeeded()
            return
        }

        guard let element = AX.focusedElement() else { clearIfNeeded(); return }

        if observedElement == nil || !CFEqual(observedElement!, element) {
            attachToFocusedElement()
        }

        // Chromium/Electron won't expose web text until we flip on their AX tree.
        enableBrowserAccessibilityIfNeeded(for: element)

        let role = AX.string(element, kAXRoleAttribute) ?? "?"
        let value = AX.string(element, kAXValueAttribute) ?? ""
        guard let axFrame = AX.frame(element) else { clearIfNeeded(); return }
        let appName = browserAppName(for: element)

        // Only act on editable surfaces (browser tab, or a native text control).
        guard appName != nil || editableRoles.contains(role) else { clearIfNeeded(); return }

        // Skip browser chrome (address bar, in-page search, …): only page
        // content — anything under an AXWebArea — is prose worth checking.
        if appName != nil, !isInWebArea(element) { clearIfNeeded(); return }

        // Re-evaluate only when the text or the field's frame changes.
        let signature = "\(role)|\(NSStringFromRect(axFrame))|\(value.hashValue)"
        if signature == lastSignature { return }
        lastSignature = signature

        if value.hashValue != lastValueHash {
            dismissed.removeAll()
            lastValueHash = value.hashValue
        }

        if value.hashValue != checkedValueHash {
            // Text changed: drop now-stale highlights and recheck after a pause.
            applyDetection([], element: element)
            scheduleRecheck(value: value, appName: appName)
        } else {
            // Position-only change (scroll/move): re-locate cached corrections.
            renderSentenceFixes(currentCorrections, fullText: currentFullText, appName: appName)
        }
    }

    /// Debounce the grammar check so fast typing doesn't fire a request per key.
    private func scheduleRecheck(value: String, appName: String?) {
        grammarDebounce?.invalidate()
        grammarDebounce = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck(value: value, appName: appName) }
        }
    }

    /// Produce corrections for the focused field (LLM if ready, else the
    /// dictionary), then locate + render them. `value` is the AX-derived text that
    /// triggered this pass (used for the change token + staleness check); for
    /// browsers we validate the DOM text so phrases match what `locate` searches.
    private func recheck(value: String, appName: String?) {
        // In a browser the text comes from the DOM (its offsets line up with the
        // rects we ask for later), and that's an Apple Event — off the main
        // thread, then continue when it lands.
        guard let appName else { recheck(value: value, appName: nil, text: value); return }
        browser.focusedText(appName: appName) { [weak self] domText in
            guard let self else { return }
            // The field may have moved on while the browser was answering.
            let current = AX.focusedElement().flatMap { AX.string($0, kAXValueAttribute) }
            guard current == value else { return }
            self.recheck(value: value, appName: appName, text: domText ?? value)
        }
    }

    private func recheck(value: String, appName: String?, text: String) {
        let token = value.hashValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            currentCorrections = []
            currentFullText = text
            checkedValueHash = token
            applyDetection([], element: AX.focusedElement())
            return
        }

        // Fast path: English goes through Harper (rules, ~ms, CPU-only, exact
        // spans). Other languages fall through to the LLM below.
        if linterHost.ready,
           NLLanguageRecognizer.dominantLanguage(for: text) == .english {
            let checkStart = CFAbsoluteTimeGetCurrent()
            isChecking = true
            linterHost.lint(text) { [weak self] lints in
                guard let self else { return }
                self.isChecking = false
                // Only apply if the field still holds the text we checked.
                let current = AX.focusedElement().flatMap { AX.string($0, kAXValueAttribute) }
                guard current == value else { return }
                let corrections = self.corrections(fromLints: lints, in: text)
                print("⚡ harper: \(lints.count) lint(s) → \(corrections.count) sentence fix(es)")
                PerfHUD.shared.lastGrammarMs = Int((CFAbsoluteTimeGetCurrent() - checkStart) * 1000)
                self.currentCorrections = corrections
                self.currentFullText = text
                self.checkedValueHash = token
                self.renderSentenceFixes(corrections, fullText: text, appName: appName)
                if self.deepCheck {
                    self.runDeepCheck(value: value, text: text, token: token,
                                      appName: appName, base: corrections)
                }
            }
            return
        }

        // LLM path — grammar may be pinned to its own model/server (per-task
        // routing); the serving model's manifest quirks drive validation.
        let grammarServer = server(for: .grammar)
        let grammarFile = taskModelFile(for: .grammar)
        let quirks = ModelManifest.byFile(grammarFile)?.validate
        let client = LLMClient(chatURL: grammarServer.chatURL,
                               echoMarkers: quirks?.echoMarkers ?? [],
                               maxGrowth: quirks?.maxGrowth ?? 2.0)
        guard grammarServer.status == .ready else {
            currentCorrections = []
            currentFullText = text
            checkedValueHash = token
            applyDetection([], element: AX.focusedElement())
            return
        }

        print("📝 validating focused input (\(text.count) chars)…")
        grammarTask?.cancel()
        let checkStart = CFAbsoluteTimeGetCurrent()
        isChecking = true
        grammarTask = Task { [weak self] in
            let corrections = await client.corrections(in: text)
            await MainActor.run { self?.isChecking = false }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                print("   → \(corrections.count) sentence fix(es)")
                PerfHUD.shared.lastGrammarMs = Int((CFAbsoluteTimeGetCurrent() - checkStart) * 1000)
                // Only apply if the field still holds the text we checked.
                let current = AX.focusedElement().flatMap { AX.string($0, kAXValueAttribute) }
                guard current == value else { print("   (stale — field changed)"); return }
                self.currentCorrections = corrections
                self.currentFullText = text
                self.checkedValueHash = token
                self.renderSentenceFixes(corrections, fullText: text, appName: appName)
            }
        }
    }

    /// For each corrected sentence, underline the changed words (diff) and carry
    /// the whole-sentence fix. Browser → rects by text offset; native →
    /// AXBoundsForRange over the value.
    private func renderSentenceFixes(_ corrections: [SentenceCorrection],
                                     fullText: String, appName: String?) {
        guard let element = AX.focusedElement(), let axFrame = AX.frame(element) else {
            applyDetection([], element: nil); return
        }
        let fieldBox = toCocoa(axFrame)
        let ns = fullText as NSString

        // Changed-word ranges (offsets into fullText) + the sentence each belongs to.
        var pendings: [Pending] = []
        for sc in corrections {
            let sentence = ns.range(of: sc.original)
            guard sentence.location != NSNotFound else { continue }
            let changed = WordDiff.changedRanges(original: sc.original, corrected: sc.corrected)
            let ranges = changed.isEmpty ? [NSRange(location: 0, length: sc.original.utf16.count)] : changed
            for r in ranges {
                pendings.append(Pending(
                    range: NSRange(location: sentence.location + r.location, length: r.length),
                    original: sc.original, corrected: sc.corrected))
            }
        }

        var words: [FlaggedWord] = []
        if let appName {
            activeBrowserAppName = appName
            // Another Apple Event, so it can't run here: the highlights land a
            // beat later instead of freezing everything until the browser answers.
            let pendingList = pendings
            browser.rects(appName: appName,
                          ranges: pendingList.map { ($0.range.location, $0.range.length) }) {
                [weak self] rs in
                guard let self else { return }
                var found: [FlaggedWord] = []
                for rr in rs ?? [] where pendingList.indices.contains(rr.index) {
                    let p = pendingList[rr.index]
                    let rect = CGRect(x: fieldBox.minX + rr.x, y: fieldBox.maxY - rr.y - rr.height,
                                      width: rr.width, height: rr.height)
                    guard self.isSaneRect(rect, in: fieldBox) else { continue }
                    found.append(FlaggedWord(rect: rect, original: p.original,
                                             corrected: p.corrected, range: nil,
                                             sentenceID: p.original))
                }
                // The page bridge only sees contenteditable, so a plain
                // <textarea> in a browser yields nothing — fall back to the AX
                // geometry the native path uses rather than showing no
                // squiggles at all.
                if found.isEmpty {
                    found = self.axWords(for: pendingList, in: ns, element: element,
                                         fieldBox: fieldBox)
                }
                found = found.filter { !self.dismissed.contains($0.id) }
                print("   highlighted \(found.count) on \(appName)")
                // Applied even when empty: that's what clears stale squiggles.
                self.applyDetection(found, element: element)
            }
            return
        } else {
            activeBrowserAppName = nil
            words = axWords(for: pendings, in: ns, element: element, fieldBox: fieldBox)
        }

        words = words.filter { !dismissed.contains($0.id) }
        if !corrections.isEmpty { print("   highlighted \(words.count) on \(appName ?? "native")") }
        applyDetection(words, element: element)
    }

    /// The pill's visual: a loader inviting the user in until the card opens,
    /// a static ring while it's open, plain blue when no model can serve it.
    private func pillState() -> PillState {
        if popoverMode == .rephrase { return .open }
        // Deliberately does NOT call server(for:), which spawns a llama-server
        // as a side effect — deciding how to draw the pill must not load a model.
        let canCheck = linterHost.ready || grammarServerStatus() == .ready
        if !canCheck { return .plain }
        return isChecking ? .loading : .idle
    }

    /// Status of the grammar server if one already exists, without creating one.
    private func grammarServerStatus() -> LLMServer.Status {
        guard let path = taskModelPath(for: .grammar) else { return llmServer.status }
        return taskServers[path]?.status ?? .stopped
    }

    /// Re-render the pill (if visible) with the current state.
    private func refreshPillState() {
        guard pillRect != nil else { return }
        pillPanel.setState(pillState())
    }

    /// Commit a set of flagged words to the overlay (and close a stale card).
    private func applyDetection(_ words: [FlaggedWord], element: AXUIElement?) {
        activeElement = element
        flagged = words
        refreshPillState()
        // Rects are global; the overlay's origin is negative when a display sits
        // left of or above the primary one.
        let offset = window.frame.origin
        let highlights = words.map {
            Highlight(rect: $0.rect.offsetBy(dx: -offset.x, dy: -offset.y), color: .systemRed)
        }
        let key = highlights
            .map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)),\(Int($0.rect.width))" }
            .joined(separator: ";")
        if key != lastHighlightsKey {
            lastHighlightsKey = key
            view.update(highlights: highlights)
        }
        if popoverMode == .grammar, let aw = activeWord,
           !words.contains(where: { $0.id == aw.id }) {
            popoverPanel.orderOut(nil)
            activeWord = nil
            hoveredID = nil
            popoverMode = .none
        }
    }

    private func frontmostIsSelf() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
    }

    /// Browser app name (for AppleScript) if the focused element belongs to one.
    private func browserAppName(for element: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier else { return nil }
        return BrowserBridge.appNames[bundleID]
    }

    // MARK: - Hover → card

    /// Driven by the global mouse monitor: open the rephrase card over the pill,
    /// or a grammar card over a flagged word; keep it open over the card; hide
    /// otherwise.
    private func handleMouseMove() {
        // In the sandbox the card is driven by the DOM (pill/squiggle hover in the
        // webview), not native hover-tracking — don't let global mouse moves close it.
        if sandboxActive { return }
        let p = NSEvent.mouseLocation

        if popoverPanel.isVisible, popoverPanel.frame.insetBy(dx: -4, dy: -4).contains(p) {
            cancelHidePopover()
            return
        }

        if let hit = flagged.first(where: { $0.rect.insetBy(dx: -2, dy: -3).contains(p) }) {
            cancelHidePopover()
            if hit.id != hoveredID || popoverMode != .grammar {
                hoveredID = hit.id
                showCard(for: hit)
            }
        } else if popoverMode != .none {
            hoveredID = nil
            scheduleHidePopover()
        }
    }

    private func showCard(for word: FlaggedWord) {
        popoverMode = .grammar
        activeWord = word
        // Grammar: Swift already has the corrected sentence; show it (no fetch).
        // Accept replaces the whole sentence.
        rewriteTarget = RewriteTarget(original: word.original, appName: activeBrowserAppName,
                                      element: activeElement, range: word.range)
        let routing = cardRouting()
        popoverPanel.setCard([
            "mode": "grammar",
            "original": word.original,
            "result": word.corrected,
            "styles": [],
            // The card fetches a friendly "why" explanation for the fix — from
            // the compose model (a grammar-only fine-tune can't explain).
            "llmUrl": chatURL(for: .compose).absoluteString,
            "llmUrls": routing.urls,
            "llmModels": routing.models,
            "capabilities": routing.caps,
            "ready": llmReady,
            "targetLanguage": targetLanguage,
            "explainFixes": explainFixes,
        ])
        popoverPanel.present(avoiding: word.rect)
    }

    private func scheduleHidePopover() {
        hideHoverTimer?.invalidate()
        hideHoverTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The card's window carries a wide transparent margin, and it
                // opens only a few points from the pill — so the window ends up
                // over the pill and the pill reports "pointer left" while the
                // pointer hasn't moved at all. Closing on that, then reopening
                // on the re-entry it causes, is what reads as flicker.
                let mouse = NSEvent.mouseLocation
                if self.popoverPanel.frame.contains(mouse)
                    || (self.pillRect?.insetBy(dx: -6, dy: -6).contains(mouse) ?? false) {
                    return
                }
                self.closePopover()
            }
        }
    }

    private func cancelHidePopover() {
        hideHoverTimer?.invalidate()
        hideHoverTimer = nil
        // Hovering the popover/pill/word counts as engagement — keep it open.
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    /// Auto-close a freshly opened popover if the user never moves onto it.
    private func startAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismissDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
    }

    private func closePopover() {
        popoverPanel.orderOut(nil)
        popoverPanel.level = .statusBar   // undo any sandbox level bump
        activeWord = nil
        hoveredID = nil
        popoverMode = .none
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    // MARK: - Rephrase (selection pill)

    /// Recompute the pill from the current selection (debounced off selection
    /// changes so we don't run JS on every caret move).
    private func scheduleSelectionUpdate(after delay: TimeInterval = 0.15) {
        selectionDebounce?.invalidate()
        selectionDebounce = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSelectionPill() }
        }
    }

    private func updateSelectionPill() {
        guard enabled, settingsPopover?.isShown != true, !frontmostIsSelf(), !isBlockedApp(),
              let element = AX.focusedElement(), let axFrame = AX.frame(element),
              AX.isEditable(element) else {
            // Selecting a sentence in an email you're reading isn't an invitation
            // to rewrite it — and we couldn't write the result back anyway.
            hidePill(); return
        }

        // Still typing: stay out of the way and come back when they pause.
        let sinceTyping = Date().timeIntervalSince(lastTypedAt)
        if sinceTyping < typingQuiet {
            if popoverMode == .none { hidePill() }
            scheduleSelectionUpdate(after: typingQuiet - sinceTyping)
            return
        }
        let fieldBox = toCocoa(axFrame)
        let appName = browserAppName(for: element)

        // No rephrase pill on browser chrome (address bar etc.) either.
        if appName != nil, !isInWebArea(element) { hidePill(); return }

        var text: String?
        var selRect: CGRect?
        var nativeRange: NSRange?
        // Real selection vs. a bare caret — only a selection is worth warming
        // models for (a focused field alone isn't a signal the card is next).
        var hasSelection = false
        // Select-all: the only case where the element's own box is a truthful
        // answer to "where is the selection", rather than Chromium's stand-in.
        var selectionSpansField = false
        /// Height of one line in this field, when we could measure it.
        var lineHeight: CGFloat?
        // Write-back route: the browser DOM path (needs Automation) when it
        // succeeds, otherwise native AX write-back (set below to nil on fallback).
        var writeAppName = appName

        // AX first, always. The browser's DOM answer is better (exact rects, and
        // a write-back route that Chromium honours) but it costs an Apple Event,
        // so it can't be on the path that decides whether to draw the pill —
        // `refineFromDOM` below fetches it off-main and refines what we drew.
        if let t = AX.string(element, kAXSelectedTextAttribute),
                  !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let cf = AX.selectedRange(element) {
            // AX fallback — works for native fields AND browsers that don't grant
            // Automation / aren't contentEditable. Write back via AX (native route).
            writeAppName = nil
            // Selection geometry, best effort: index-based range bounds → text-
            // marker bounds (the VoiceOver channel — works in Chromium/Electron
            // where index bounds fail) → first-character bounds → the mouse
            // position clamped into the field. Never the whole field.
            let firstChar = CFRange(location: cf.location, length: min(1, max(0, cf.length)))
            // Never the mouse: a keyboard-made selection has nothing to do
            // with where the cursor happens to rest.
            selRect = lineRect(AX.bounds(of: cf, in: element), fieldBox)
                ?? lineRect(AX.selectionMarkerBounds(element), fieldBox)
                ?? lineRect(AX.bounds(of: firstChar, in: element), fieldBox)
            // One character's height is one line's height — the yardstick for
            // telling a selection that wraps from one that doesn't. A union rect
            // can't answer that on its own: a tall one might be three lines or
            // one line in a large font.
            lineHeight = lineRect(AX.bounds(of: firstChar, in: element), fieldBox)?.height
            let length = (AX.string(element, kAXValueAttribute) as NSString?)?.length ?? 0
            selectionSpansField = cf.location == 0 && cf.location + cf.length >= length && length > 0
            let selRange = NSRange(location: cf.location, length: cf.length)
            if t.contains("\n") {
                // Multi-line: expand to whole sentence(s).
                let full = (AX.string(element, kAXValueAttribute) ?? "") as NSString
                let expanded = sentenceRange(covering: selRange, in: full)
                text = full.substring(with: expanded)
                nativeRange = expanded
            } else {
                text = t
                nativeRange = selRange
            }
            hasSelection = true
        } else if let cf = AX.selectedRange(element), cf.length == 0,
                  let full = AX.string(element, kAXValueAttribute),
                  !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Nothing selected — sit beside the caret's own line and act on the
            // sentence around it. The caret's *marker* range is what yields a
            // real rect in Chromium (index-based bounds come back as an empty
            // box there), which is what makes this work in Gmail and Slack.
            writeAppName = nil
            let ns = full as NSString
            let caret = min(max(cf.location, 0), ns.length)
            let expanded = sentenceRange(covering: NSRange(location: caret, length: 0), in: ns)
            text = ns.substring(with: expanded)
            nativeRange = expanded
            selRect = lineRect(AX.selectionMarkerBounds(element), fieldBox)
                ?? lineRect(AX.bounds(of: CFRange(location: caret, length: 0), in: element), fieldBox)
        }

        // Chromium answers the *same* geometry query intermittently with the
        // element's own box instead of the line. Those answers are filtered out
        // above, so hold the last believable position through them — a marker
        // that blinks away every few queries is worse than one that lags a beat.
        if let good = selRect {
            lastAnchor = (element, good)
        } else if let last = lastAnchor, CFEqual(last.element, element) {
            selRect = last.rect
        } else if selectionSpansField {
            // Last resort for a select-all with no usable geometry and nothing
            // cached: hang a capsule from the field's first line, where the
            // selection certainly starts. Capped, because a field is often far
            // taller than the text in it and a capsule spanning empty space
            // reads as a bug.
            let height = min(fieldBox.height - 4, 96)
            selRect = CGRect(x: fieldBox.minX, y: fieldBox.maxY - height,
                             width: fieldBox.width, height: height)
        }

        guard let target = text, let r = selRect,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isInsideField(r, fieldBox) else {
            // Chromium's first geometry answer after a focus change is often the
            // junk box, and there's no cached anchor yet to fall back on. One
            // retry turns "no pill until you move the caret" into a brief wait.
            if text != nil, selRect == nil, !retriedAnchor {
                retriedAnchor = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.updateSelectionPill()
                }
            }
            hidePill(); return
        }
        retriedAnchor = false

        rephraseText = target
        rephraseAppName = writeAppName
        rephraseElement = element
        rephraseRange = nativeRange

        // Pill in the field's left margin, centred on the *first* line of the
        // selection — anchoring to its middle would push the pill halfway down
        // a multi-line selection, far from where the eye is. A selection grows
        // it into a capsule so it reads as acting on a passage rather than
        // marking a spot. Clamped into the field so a partly-scrolled selection
        // doesn't strand it outside.
        showPill(at: r, in: fieldBox, hasSelection: hasSelection, lineHeight: lineHeight)
        if let appName, hasSelection {
            refineSelectionFromDOM(appName: appName, element: element,
                                   fieldBox: fieldBox, axText: target)
        }

        // A selection means the card is likely next — spawn any cold task
        // servers now so their models are loading before the user hovers.
        // (Grammar only needs the LLM when Harper won't cover the text.)
        guard hasSelection else { return }
        _ = server(for: .compose)
        if deepCheck
            || !(linterHost.ready
                 && NLLanguageRecognizer.dominantLanguage(for: target) == .english) {
            _ = server(for: .grammar)
        }
    }

    /// Hovering the pill opens the card after a short dwell, so brushing past it
    /// with the cursor doesn't fire it. Applies to the caret pill too, not just
    /// a selection — note the card takes key focus when it opens, so resting the
    /// pointer on the pill mid-sentence will interrupt typing.
    private func startPillDwell() {
        cancelPillDwell()
        pillDwell = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pillRect != nil, self.popoverMode != .rephrase else { return }
                self.showRephrase()
            }
        }
    }

    private func cancelPillDwell() {
        pillDwell?.invalidate()
        pillDwell = nil
    }

    /// A changed-word range plus the sentence it belongs to, waiting to be
    /// turned into a screen rect by whichever geometry source answers.
    struct Pending { let range: NSRange; let original: String; let corrected: String }

    /// Highlight rects straight from the Accessibility API, a line at a time.
    /// AXBoundsForRange unions a multi-line range into one giant box, so ranges
    /// are split at newlines first.
    private func axWords(for pendings: [Pending], in ns: NSString,
                         element: AXUIElement, fieldBox: CGRect) -> [FlaggedWord] {
        var words: [FlaggedWord] = []
        for p in pendings {
            let sentence = ns.range(of: p.original)
            for sub in Self.splitAtNewlines(p.range, in: ns) {
                guard let rect = screenRect(for: sub, in: element),
                      isSaneRect(rect, in: fieldBox) else { continue }
                words.append(FlaggedWord(rect: rect, original: p.original, corrected: p.corrected,
                                         range: sentence.location != NSNotFound ? sentence : nil,
                                         sentenceID: p.original))
            }
        }
        return words
    }

    /// Place the pill beside `r` — a selection grows it into a capsule spanning
    /// the passage; a bare caret keeps the disc, centred on its line. Clamped
    /// into the field so a partly-scrolled selection doesn't strand it outside.
    private func showPill(at r: CGRect, in fieldBox: CGRect, hasSelection: Bool,
                          lineHeight: CGFloat? = nil) {
        let width: CGFloat = 16
        // Only a selection that actually wraps gets a capsule. One line — however
        // many words — is the same disc as the caret, so the marker changes shape
        // when the selection changes shape, not merely when one exists.
        let line = lineHeight ?? r.height
        let wraps = hasSelection && r.height > line * 1.5
        let height = wraps ? min(r.height, fieldBox.height - 4) : width
        let anchorY = wraps ? r.midY : r.maxY - min(r.height, line) / 2
        let x = max(2, fieldBox.minX - width - 4)
        let y = min(max(anchorY - height / 2, fieldBox.minY + 2),
                    max(fieldBox.minY + 2, fieldBox.maxY - height - 2))
        let pill = CGRect(x: x, y: y, width: width, height: height)
        pillRect = pill
        pillOnSelection = hasSelection
        pillPanel.show(at: pill, state: pillState())
    }

    /// Ask the page where the selection actually is, off the main thread, and
    /// adjust the pill once it answers. The DOM's rects are exact where
    /// Chromium's AX geometry is guesswork, and its write-back route (execCommand)
    /// is the one the editor's own model notices — but neither is worth blocking
    /// the main thread for, so we draw from AX first and correct ourselves here.
    private func refineSelectionFromDOM(appName: String, element: AXUIElement,
                                        fieldBox: CGRect, axText: String) {
        browser.selection(appName: appName) { [weak self] sel in
            guard let self, let sel, self.pillRect != nil,
                  self.popoverMode != .rephrase,       // don't move a card's anchor
                  AX.focusedElement().map({ CFEqual($0, element) }) == true,
                  // The user may have selected something else in the meantime.
                  AX.string(element, kAXSelectedTextAttribute) == axText else { return }
            let rect = CGRect(x: fieldBox.minX + sel.x, y: fieldBox.maxY - sel.y - sel.height,
                              width: sel.width, height: sel.height)
            guard self.isInsideField(rect, fieldBox) else { return }
            self.rephraseText = (sel.multiline && !sel.sentence.isEmpty) ? sel.sentence : sel.text
            self.rephraseAppName = appName          // write back through the DOM
            self.rephraseRange = nil
            self.showPill(at: rect, in: fieldBox, hasSelection: true)
        }
    }

    private func hidePill() {
        cancelPillDwell()
        pillOnSelection = false
        guard pillRect != nil else { return }
        pillRect = nil
        pillPanel.hide()
        if popoverMode == .rephrase {
            popoverPanel.orderOut(nil)
            popoverPanel.level = .statusBar   // undo any sandbox level bump
            popoverMode = .none
        }
    }

    private static let styleList: [[String: String]] =
        RewriteStyle.allCases.map { ["id": $0.rawValue, "label": $0.label] }

    /// Open the rewrite card on the selection. React fetches all styles from the
    /// local LLM directly; Swift only supplies the text + LLM URL and applies the
    /// accepted result.
    private func showRephrase() {
        guard let text = rephraseText else { return }
        popoverMode = .rephrase
        rewriteTarget = RewriteTarget(original: text, appName: rephraseAppName,
                                      element: rephraseElement, range: rephraseRange)
        // English selections get their Grammar tab from Harper — computed here,
        // shown instantly, no LLM involved.
        if linterHost.ready, NLLanguageRecognizer.dominantLanguage(for: text) == .english {
            linterHost.lint(text) { [weak self] lints in
                guard let self, self.popoverMode == .rephrase,
                      self.rephraseText == text else { return }
                let ns = text as NSString
                var corrected = ns
                for lint in lints.sorted(by: { $0.range.location > $1.range.location })
                where !lint.suggestions.isEmpty {
                    guard lint.range.location + lint.range.length <= corrected.length else { continue }
                    corrected = corrected.replacingCharacters(
                        in: lint.range, with: lint.suggestions[0]) as NSString
                }
                self.presentRephraseCard(text: text, grammarResult: corrected as String)
            }
        } else {
            presentRephraseCard(text: text, grammarResult: nil)
        }
    }

    private func presentRephraseCard(text: String, grammarResult: String?) {
        let routing = cardRouting()
        var models = routing.models
        if grammarResult != nil { models["grammar"] = "Harper (rules)" }
        var payload: [String: Any] = [
            "mode": "rewrite",
            "original": text,
            "result": "",
            "styles": Self.styleList,
            "llmUrl": chatURL(for: .compose).absoluteString,
            "llmUrls": routing.urls,
            "llmModels": models,
            "capabilities": routing.caps,
            "ready": llmReady,
            "targetLanguage": targetLanguage,
            "explainFixes": explainFixes,
        ]
        if let grammarResult { payload["grammarResult"] = grammarResult }
        popoverPanel.setCard(payload)
        popoverPanel.present(avoiding: pillRect ?? .zero)
        refreshPillState()   // loading → open (static ring) while the card is up
    }

    /// Register the global shortcut that opens the rephrase card on the current
    /// selection. Default ⌘` (backtick); overridable via UserDefaults.
    private func registerRephraseHotKey() {
        let d = UserDefaults.standard
        let keyCode = UInt32(d.object(forKey: "rephraseHotKeyCode") as? Int ?? kVK_ANSI_Grave)
        let modifiers = UInt32(d.object(forKey: "rephraseHotKeyModifiers") as? Int ?? cmdKey)
        rephraseHotKey = GlobalHotKey(keyCode: keyCode, modifiers: modifiers) { [weak self] in
            MainActor.assumeIsolated { self?.triggerRephraseHotKey() }
        }
        if rephraseHotKey == nil {
            print("⚠️ Couldn't register the rephrase hotkey (another app may own it).")
        }
    }

    /// Hotkey pressed: toggle the rephrase card for the current selection.
    private func triggerRephraseHotKey() {
        if popoverMode == .rephrase { hidePill(); return }   // already open → close
        guard enabled, popoverMode == .none else { return }  // don't fight the grammar card

        // Onboarding sandbox: open the real card over our own textarea (⌘` or the
        // pill both route here).
        if sandboxActive { openSandboxCard(); return }

        updateSelectionPill()                                 // recompute selection + pill
        if rephraseText != nil, pillRect != nil {
            // No auto-dismiss: the user asked for this card with a keystroke and
            // may never bring the mouse near it. Esc, ⌘` again, or moving the
            // selection all close it.
            showRephrase()
        }
    }

    /// Open the real rephrase card over the onboarding sandbox textarea, sourcing
    /// its text + rect from the webview DOM (AX can't see our own webview). Driven
    /// by ⌘` or hovering the sandbox pill. Stays open until the user acts.
    private func openSandboxCard() {
        guard popoverMode == .none else { return }
        settingsPopover?.sandboxField { [weak self] text, rect in
            guard let self, self.sandboxActive, self.popoverMode == .none else { return }
            self.rephraseText = text
            self.rephraseAppName = nil
            self.rephraseElement = nil
            self.rephraseRange = nil
            self.pillRect = rect
            // The onboarding panel is key at .statusBar; lift the card above it so
            // it never renders behind the onboarding window.
            self.popoverPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            self.showRephrase()
        }
    }

    /// Open the real grammar card for a scripted sandbox mistake (original →
    /// corrected), anchored at the squiggle's screen rect. Accept writes back via
    /// the DOM bridge (`applyRewrite` → sandbox path).
    private func openSandboxGrammarCard(original: String, corrected: String, rect: CGRect) {
        guard popoverMode == .none else { return }
        popoverMode = .grammar
        activeWord = FlaggedWord(rect: rect, original: original, corrected: corrected,
                                 range: nil, sentenceID: original)
        rewriteTarget = RewriteTarget(original: original, appName: nil, element: nil, range: nil)
        let routing = cardRouting()
        popoverPanel.setCard([
            "mode": "grammar",
            "original": original,
            "result": corrected,
            "styles": [],
            "llmUrl": chatURL(for: .compose).absoluteString,
            "llmUrls": routing.urls,
            "llmModels": routing.models,
            "capabilities": routing.caps,
            "ready": llmReady,
            "targetLanguage": targetLanguage,
            "explainFixes": explainFixes,
        ])
        popoverPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        popoverPanel.present(avoiding: rect)
    }

    /// Write `text` into the current target (browser DOM or native AX).
    private func applyRewrite(text: String) {
        guard !text.isEmpty else { return }
        // Sandbox writes back through the DOM (the textarea is uncontrolled, so it
        // sticks) rather than AX, and tells the sandbox UI to tick its checkmark.
        if sandboxActive {
            settingsPopover?.setSandboxField(text)
            settingsPopover?.notifySandboxApplied(text)
            return
        }
        guard let target = rewriteTarget else { return }
        if let appName = target.appName {
            browser.replaceText(appName: appName, original: target.original, replacement: text)
        } else if let element = target.element {
            if let range = target.range {
                var cf = CFRange(location: range.location, length: range.length)
                if let axRange = AXValueCreate(.cfRange, &cf) {
                    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
                }
            }
            let before = AX.string(element, kAXValueAttribute)
            AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            // Chromium/Electron (Slack, VS Code, …) report success but silently
            // ignore AX text writes. If the field value didn't change, fall back
            // to pasting over the selection — the range set above (or the user's
            // own selection) marks the text to replace.
            let after = AX.string(element, kAXValueAttribute)
            if before == after {
                // Paste replaces the current selection — only safe if it holds
                // exactly the text we're replacing (guards against the range set
                // above also having been ignored, which would paste at the caret).
                let selected = AX.string(element, kAXSelectedTextAttribute) ?? ""
                guard selected.trimmingCharacters(in: .whitespacesAndNewlines)
                    == target.original.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    print("⚠️ AX write-back ignored and selection mismatch — not pasting")
                    return
                }
                print("⌨️ AX write-back ignored — typing instead")
                typeReplace(text)
            }
        }
    }

    /// Replace the focused app's current selection by synthesizing `text` as
    /// keyboard input (CGEvent unicode strings) — typing over a selection
    /// replaces it, and unlike a ⌘V fallback the clipboard is never touched.
    /// Delayed a beat so the card panel has closed and key focus is back in the
    /// target app before the events land.
    private func typeReplace(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let utf16 = Array(text.utf16)
            // CGEvent carries ~20 UTF-16 units per event; chunk longer text.
            var start = 0
            while start < utf16.count {
                let chunk = Array(utf16[start..<min(start + 20, utf16.count)])
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down?.post(tap: .cghidEventTap)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                up?.post(tap: .cghidEventTap)
                start += 20
            }
        }
    }

    private func finishRephrase() {
        popoverPanel.orderOut(nil)
        popoverPanel.level = .statusBar   // undo any sandbox level bump
        popoverMode = .none
        rewriteTarget = nil
        hidePill()
        lastSignature = ""       // the text changed — re-evaluate next tick
        checkedValueHash = 0
    }

    // MARK: - Messages from the React card

    private func handleWebMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "resize":
            if let width = (body["width"] as? NSNumber)?.doubleValue,
               let height = (body["height"] as? NSNumber)?.doubleValue {
                popoverPanel.resize(toContentWidth: CGFloat(width), height: CGFloat(height))
            }
        case "applyRewrite":
            if let text = body["text"] as? String { applyRewrite(text: text) }
            finishRephrase()
        case "dismiss":
            // For grammar, suppress the sentence so it stops being flagged.
            if popoverMode == .grammar, let word = activeWord { dismissed.insert(word.id) }
            finishRephrase()
        case "openSettings":
            // A capability disclaimer's "Open Settings" — close the card first.
            finishRephrase()
            openSettings()
        default:
            break
        }
    }

    /// Force a Chromium/Electron app to build and expose its accessibility tree.
    /// Setting `AXManualAccessibility` (and the legacy `AXEnhancedUserInterface`)
    /// on the app element is the documented switch ATs use. Done once per PID.
    private func enableBrowserAccessibilityIfNeeded(for element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }
        enableBrowserAccessibility(pid: pid)
    }

    /// Same, keyed off a pid directly — called on app activation, because a
    /// fresh Chromium/Electron process may expose NO focused element until the
    /// switch is flipped (so the element-based path never triggers).
    private func enableBrowserAccessibility(pid: pid_t) {
        guard !a11yEnabledPids.contains(pid),
              let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier,
              Self.browserBundleIDs.contains(bundleID)
        else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        a11yEnabledPids.insert(pid)
        print("🌐 enabled AX tree for \(bundleID) (pid \(pid)) — refocus the field")
    }

    // MARK: - Menu bar + settings

    /// The Nib pen glyph as a menu-bar template image (1x + 2x reps, tinted by
    /// the system for light/dark menu bars).
    private static func menuBarIcon() -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for name in ["nib-menubar-18", "nib-menubar-36"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "png"),
               let rep = NSImageRep(contentsOf: url) {
                rep.size = NSSize(width: 18, height: 18)
                image.addRepresentation(rep)
            }
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        return image
    }

    /// Put a small icon in the menu bar; clicking it opens the settings popover.
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = Self.menuBarIcon()
                ?? NSImage(systemSymbolName: "checkmark.bubble", accessibilityDescription: "Nib") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Nib"
            }
            button.toolTip = "Nib — writing suggestions"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Left-click opens settings; right-click (or control-click) shows a menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            showStatusMenu()
        } else {
            openSettings()
        }
    }

    /// Every app the user could plausibly type in, for the settings list. Built
    /// on demand (icons make it too heavy for the regular state push) off the
    /// main thread, then handed back.
    private func sendInstalledApps() {
        let folders = ["/Applications", "/System/Applications",
                       NSHomeDirectory() + "/Applications"]
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var bundles: [URL] = []
            for folder in folders {
                guard let entries = try? fm.contentsOfDirectory(
                    at: URL(fileURLWithPath: folder),
                    includingPropertiesForKeys: nil) else { continue }
                for entry in entries {
                    if entry.pathExtension == "app" {
                        bundles.append(entry)
                    } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                        .isDirectory == true {
                        // One level down catches /Applications/Utilities and the
                        // folders people file their apps into.
                        let nested = (try? fm.contentsOfDirectory(
                            at: entry, includingPropertiesForKeys: nil)) ?? []
                        bundles.append(contentsOf: nested.filter { $0.pathExtension == "app" })
                    }
                }
            }
            var seen = Set<String>()
            var apps: [[String: Any]] = []
            for url in bundles {
                guard let bundle = Bundle(url: url),
                      let id = bundle.bundleIdentifier,
                      !seen.contains(id) else { continue }
                seen.insert(id)
                let named = [bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
                             bundle.infoDictionary?["CFBundleDisplayName"] as? String,
                             bundle.infoDictionary?["CFBundleName"] as? String]
                // Some bundles carry an empty name key rather than none at all.
                let name = named.compactMap { $0 }.first { !$0.isEmpty }
                    ?? url.deletingPathExtension().lastPathComponent
                var entry: [String: Any] = ["id": id, "name": name]
                if let png = Self.iconPNG(forApp: url.path) {
                    entry["icon"] = "data:image/png;base64," + png.base64EncodedString()
                }
                apps.append(entry)
            }
            apps.sort {
                (($0["name"] as? String) ?? "").localizedCaseInsensitiveCompare(
                    ($1["name"] as? String) ?? "") == .orderedAscending
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.settingsPopover?.setApps(apps) }
            }
        }
    }

    /// A 32pt app icon as PNG data. Drawn into a small bitmap on purpose:
    /// setting NSImage.size leaves the underlying representation at full
    /// resolution, so encoding it straight yields ~1MB per app (and minutes for
    /// a whole disk's worth), against ~2KB this way.
    private nonisolated static func iconPNG(forApp path: String) -> Data? {
        let side = 32
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Record an app as "where the user is working", ignoring ourselves — the
    /// settings window and the status menu both make us frontmost.
    private func rememberActiveApp(_ app: NSRunningApplication?) {
        guard let app, let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier,
              !id.hasPrefix("com.apple.loginwindow") else { return }
        let name = app.localizedName ?? id
        guard lastActiveApp?.id != id else { return }
        lastActiveApp = (id, name)
        // The settings screen offers a one-tap switch for this app.
        if settingsPopover?.isShown == true { pushSettingsState() }
    }

    private func isInWebArea(_ element: AXUIElement) -> Bool {
        if let cached = cachedWebArea, CFEqual(cached.element, element) { return cached.isWeb }
        let isWeb = AX.isInWebArea(element)
        cachedWebArea = (element, isWeb)
        return isWeb
    }

    /// Whether Nib is switched off for the app in front right now.
    private func isBlockedApp() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return blockedApps[id] != nil
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        if let app = lastActiveApp ?? NSWorkspace.shared.frontmostApplication.flatMap({
            guard let id = $0.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
            return (id, $0.localizedName ?? id)
        }) {
            let blocked = blockedApps[app.id] != nil
            let item = NSMenuItem(title: blocked ? "Turn on for \(app.name)"
                                                 : "Turn off for \(app.name)",
                                  action: #selector(toggleBlockedApp), keyEquivalent: "")
            item.target = self
            item.representedObject = app.id
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let hud = NSMenuItem(title: PerfHUD.shared.visible ? "Hide Performance HUD" : "Show Performance HUD",
                             action: #selector(togglePerfHUD), keyEquivalent: "")
        hud.target = self
        menu.addItem(hud)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Nib",
                              action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func toggleBlockedApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if blockedApps.removeValue(forKey: id) == nil {
            blockedApps[id] = lastActiveApp?.name ?? id
            clearOverlay()          // stop marking what we just switched off
        }
        UserDefaults.standard.set(blockedApps, forKey: "blockedApps")
        lastSignature = ""          // re-check on the next tick if it was unblocked
        pushSettingsState()
    }

    @objc private func togglePerfHUD() {
        PerfHUD.shared.toggle()
    }

    /// ⌘Q, logout, or any quit that isn't our own menu item. Without this the
    /// llama-server children outlive the app, reparent to launchd, and keep
    /// multiple GB of model weights resident with nothing to reclaim them.
    func applicationWillTerminate(_ notification: Notification) {
        stopAllServers()
    }

    private func stopAllServers() {
        llmServer.stop()
        taskServers.values.forEach { $0.stop() }
    }

    /// AppKit's termination path doesn't run for a bare signal, so `kill`,
    /// `pkill` and a crashing parent shell would all strand the model servers.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)          // let the dispatch source see it instead
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.stopAllServers()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    @objc private func quitFromMenu() {
        llmServer.stop()
        taskServers.values.forEach { $0.stop() }
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        guard let button = statusItem?.button else { return }
        if settingsPopover == nil {
            let popover = SettingsPopover(url: Self.webURL())
            popover.onMessage = { [weak self] body in self?.handleSettingsMessage(body) }
            settingsPopover = popover
        }
        // Toggle — but the onboarding runs at normal level and can be buried
        // under other windows: first click surfaces it, a click while it's
        // frontmost closes it.
        if settingsPopover?.isShown == true {
            if settingsPopover?.isKeyPanel == true {
                settingsPopover?.close()
            } else {
                settingsPopover?.bringToFront()
            }
            return
        }
        // Until onboarding is completed, show it centered on screen; afterwards
        // settings hangs under the menu-bar icon.
        if LLMPaths.onboardingCompleted() {
            settingsPopover?.show(relativeTo: button)
        } else {
            settingsPopover?.showCentered()
        }
        pushSettingsState()
    }

    /// Dock icon clicked (it's visible while settings/onboarding is open, since
    /// the app runs as .regular then): surface a buried panel.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if settingsPopover?.isShown == true { settingsPopover?.bringToFront() }
        return false
    }

    /// Accessibility granted and a model is configured.
    private var isSetUp: Bool {
        AXIsProcessTrusted() && LLMPaths.resolveModel() != nil
    }

    /// Where the React UI comes from. Resolution order:
    ///   1. LOCO_WEB_URL (e.g. http://localhost:5173 for live web dev)
    ///   2. the app bundle's Resources/web (the shipped app)
    ///   3. the built web/dist next to the repo (dev, run from the project root)
    ///   4. localhost:5173 as a last resort
    private static func webURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["LOCO_WEB_URL"],
           let url = URL(string: raw) {
            return url
        }
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("web/index.html"),
           fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        let dist = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("web/dist/index.html")
        if fm.fileExists(atPath: dist.path) {
            return dist
        }
        return URL(string: "http://localhost:5173")!
    }

    /// Let the user pick a .gguf model; persist it and reload the LLM server.
    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.message = "Choose a GGUF model"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let gguf = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [gguf]
        }
        // Open in the folder of the current model (resolving symlinks to the real file).
        if let current = LLMPaths.resolveModel() {
            panel.directoryURL = URL(fileURLWithPath: current)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
        }
        NSApp.activate(ignoringOtherApps: true)
        // The settings/onboarding panel floats at .statusBar, above the picker —
        // drop it while the picker is modal so it doesn't obscure it.
        settingsPopover?.lowerBelowModal()
        let response = panel.runModal()
        settingsPopover?.restoreLevel()
        guard response == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "modelPath")
        llmReady = false
        llmServer.restart()
        pushSettingsState()
    }

    // MARK: - Model catalog (Hugging Face downloads)

    /// What a model can be trusted with. Raw values are shared with the web UI
    /// (and the manifest's capabilities arrays).
    enum ModelCapability: String, CaseIterable {
        case grammar      // inline squiggles + the Grammar tab
        case compose      // rephrase / shorten / refine / explainers
        case translate    // the Translate tab
    }

    /// Capabilities of the model at `path` — manifest lookup by file name;
    /// unknown (user-supplied) models are assumed fully capable.
    private static func capabilities(ofModelAt path: String?) -> Set<ModelCapability> {
        guard let path,
              let model = ModelManifest.byFile(URL(fileURLWithPath: path).lastPathComponent)
        else { return Set(ModelCapability.allCases) }
        return Set(model.capabilities.compactMap(ModelCapability.init(rawValue:)))
    }

    // MARK: - Per-task model routing

    /// The catalog id pinned to `task`, or nil for "use the default model".
    private func taskModelID(for task: LLMTask) -> String? {
        UserDefaults.standard.string(forKey: "taskModel.\(task.rawValue)")
    }

    /// Absolute path of the model pinned to `task`, nil when it should use the
    /// default (unset, unknown id, or the file is gone). Pins are either a
    /// catalog id or "file:<name>" for a user-supplied .gguf in the models dir.
    private func taskModelPath(for task: LLMTask) -> String? {
        guard let id = taskModelID(for: task) else { return nil }
        let file: String
        if id.hasPrefix("file:") {
            file = String(id.dropFirst("file:".count))
        } else if let model = ModelManifest.byID(id) {
            file = model.file
        } else {
            return nil
        }
        let path = LLMPaths.modelsDir.appendingPathComponent(file).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Pinning the same model as the default is a no-op — share the server.
        if path == LLMPaths.resolveModel() { return nil }
        return path
    }

    /// User-supplied .gguf files in the models dir (not from the catalog),
    /// selectable per task alongside catalog models.
    private func customModelFiles() -> [String] {
        let catalogFiles = Set(ModelManifest.models.map(\.file))
        let items = (try? FileManager.default.contentsOfDirectory(
            atPath: LLMPaths.modelsDir.path)) ?? []
        return items
            .filter { $0.hasSuffix(".gguf") && !$0.hasPrefix(".") && !catalogFiles.contains($0) }
            .sorted()
    }

    /// The server responsible for `task`: a warm task server for pinned models,
    /// else the main one. Spawns the task server on first use.
    private func server(for task: LLMTask) -> LLMServer {
        guard let path = taskModelPath(for: task) else { return llmServer }
        if let existing = taskServers[path] { existing.lastUsed = Date(); return existing }
        let server = LLMServer(port: nextTaskPort, modelPath: path)
        nextTaskPort += 1
        server.onStatusChange = { [weak self] status in
            guard let self else { return }
            if status == .ready {
                // Re-run detection now that the (possibly grammar) server is up.
                self.lastSignature = ""
                self.checkedValueHash = 0
                self.tick()
            }
        }
        taskServers[path] = server
        server.start()
        print("🧠 LLM: task server for \(URL(fileURLWithPath: path).lastPathComponent) on port \(server.port)")
        return server
    }

    /// Chat URL serving `task` right now.
    private func chatURL(for task: LLMTask) -> URL { server(for: task).chatURL }

    /// Whether `task`'s backing model supports it (capability check).
    private func taskSupported(_ task: LLMTask) -> Bool {
        let path = taskModelPath(for: task) ?? LLMPaths.resolveModel()
        let cap: ModelCapability = switch task {
        case .grammar: .grammar
        case .compose: .compose
        case .translate: .translate
        }
        return Self.capabilities(ofModelAt: path).contains(cap)
    }

    /// Shut down task servers whose model no longer backs any task (after
    /// reassignment), so memory isn't held by orphaned models.
    private func pruneTaskServers() {
        let needed = Set(LLMTask.allCases.compactMap { taskModelPath(for: $0) })
        for (path, server) in taskServers where !needed.contains(path) {
            server.stop()
            taskServers[path] = nil
            print("🧠 LLM: stopped task server for \(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }

    /// Task servers are spawned on demand (opening a card) but a resident model
    /// is gigabytes — stop any that haven't served a task in 10 minutes. They
    /// respawn transparently on next use (the card shows its loading state).
    private func reapIdleTaskServers() {
        for (path, server) in taskServers
        where Date().timeIntervalSince(server.lastUsed) > 600 {
            server.stop()
            taskServers[path] = nil
            print("🧠 LLM: idle task server stopped (\(URL(fileURLWithPath: path).lastPathComponent))")
        }
    }

    /// Model file name backing `task` (pinned or the default model).
    private func taskModelFile(for task: LLMTask) -> String {
        let path = taskModelPath(for: task) ?? LLMPaths.resolveModel()
        return path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
    }

    /// Payload fragments the card needs to route + gate + label its tabs.
    private func cardRouting()
        -> (urls: [String: String], caps: [String: Bool], models: [String: String]) {
        let urls = [
            "grammar": chatURL(for: .grammar).absoluteString,
            "compose": chatURL(for: .compose).absoluteString,
            "translate": chatURL(for: .translate).absoluteString,
        ]
        let caps = [
            "grammar": taskSupported(.grammar),
            "compose": taskSupported(.compose),
            "translate": taskSupported(.translate),
        ]
        let models = [
            "grammar": taskModelFile(for: .grammar),
            "compose": taskModelFile(for: .compose),
            "translate": taskModelFile(for: .translate),
        ]
        return (urls, caps, models)
    }

    /// Catalog ids whose file is already on disk (no need to re-download).
    private func downloadedModelIDs() -> [String] {
        ModelManifest.models
            .filter {
                FileManager.default.fileExists(
                    atPath: LLMPaths.modelsDir.appendingPathComponent($0.file).path)
            }
            .map(\.id)
    }

    /// Activate an already-downloaded catalog model (no download).
    private func selectModel(id: String) {
        guard let model = ModelManifest.byID(id) else { return }
        let dest = LLMPaths.modelsDir.appendingPathComponent(model.file)
        guard FileManager.default.fileExists(atPath: dest.path) else { return }
        UserDefaults.standard.set(dest.path, forKey: "modelPath")
        llmReady = false
        llmServer.restart()
        pushSettingsState()
    }

    private func startModelDownload(id: String) {
        guard modelDownload == nil,
              let model = ModelManifest.byID(id) else { return }
        try? FileManager.default.createDirectory(
            at: LLMPaths.modelsDir, withIntermediateDirectories: true)
        let dest = LLMPaths.modelsDir.appendingPathComponent(model.file)
        // Already on disk — just activate it.
        if FileManager.default.fileExists(atPath: dest.path) {
            selectModel(id: id)
            return
        }
        print("⬇️ downloading \(model.file)…")

        let task = URLSession.shared.downloadTask(with: model.url) { [weak self] tmp, response, error in
            // Move the file off-main (it can be a cross-volume copy of gigabytes);
            // URLSession deletes tmp when this handler returns, so do it here.
            var moveError: String?
            if let tmp, error == nil {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status >= 400 {
                    moveError = "Download failed (HTTP \(status))"
                } else {
                    try? FileManager.default.removeItem(at: dest)
                    do { try FileManager.default.moveItem(at: tmp, to: dest) }
                    catch { moveError = error.localizedDescription }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.modelDownloadProgress = nil
                    self.modelDownload = nil
                    if let error {
                        if (error as NSError).code != NSURLErrorCancelled {
                            self.settingsPopover?.setDownload(id: id, progress: 0,
                                                              error: error.localizedDescription)
                        }
                        return
                    }
                    if let moveError {
                        self.settingsPopover?.setDownload(id: id, progress: 0, error: moveError)
                        return
                    }
                    print("⬇️ downloaded \(model.file)")
                    UserDefaults.standard.set(dest.path, forKey: "modelPath")
                    self.settingsPopover?.setDownload(id: id, progress: 1, done: true)
                    self.llmReady = false
                    self.llmServer.restart()
                    self.pushSettingsState()
                }
            }
        }

        // Progress → UI, throttled to whole percents to avoid spamming evaluateJS.
        var lastPercent = -1
        modelDownloadProgress = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let percent = Int(p.fractionCompleted * 100)
            guard percent != lastPercent else { return }
            lastPercent = percent
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.settingsPopover?.setDownload(id: id, progress: p.fractionCompleted)
                }
            }
        }
        modelDownload = task
        task.resume()
        settingsPopover?.setDownload(id: id, progress: 0)
    }

    private func cancelModelDownload() {
        modelDownload?.cancel()
        modelDownloadProgress = nil
        modelDownload = nil
    }

    /// The app's marketing version ("dev" for bare `swift run` builds).
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Ask GitHub for the latest release and report it to the settings UI.
    /// Uses the web "latest" URL, whose redirect target ends in the version tag
    /// — the REST API allows only 60 anonymous calls/hour per IP and then 403s
    /// ("Couldn't reach GitHub" for anyone behind a busy NAT).
    private func checkForUpdates() {
        let latestURL = URL(string: "https://github.com/taranek/nib/releases/latest")!
        var request = URLRequest(url: latestURL)
        request.httpMethod = "HEAD"
        let current = appVersion
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            var latest: String?
            var page = latestURL.absoluteString
            if let finalURL = (response as? HTTPURLResponse)?.url,
               finalURL.path.contains("/releases/tag/") {
                let tag = finalURL.lastPathComponent
                latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                page = finalURL.absoluteString
            } else if let error {
                print("⚠️ update check failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.settingsPopover?.setUpdateStatus(current: current, latest: latest, url: page)
                }
            }
        }.resume()
    }

    /// Self-update: download the release zip, stage the new bundle, then swap
    /// it in and relaunch after this process exits. Only for packaged installs —
    /// dev builds fall back to opening the release page.
    private func installUpdate(version: String, pageURL: String) {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            if let url = URL(string: pageURL) { NSWorkspace.shared.open(url) }
            return
        }
        let zipURL = URL(string: "https://github.com/taranek/nib/releases/download/v\(version)/Nib.zip")!
        let progressID = "app-update"
        settingsPopover?.setDownload(id: progressID, progress: 0)

        let task = URLSession.shared.downloadTask(with: zipURL) { [weak self] tmp, response, error in
            let fm = FileManager.default
            var staged: String?
            var failure: String?
            if let error {
                failure = error.localizedDescription
            } else if let tmp, ((response as? HTTPURLResponse)?.statusCode ?? 0) < 400 {
                // Unpack in tmp and verify the staged bundle is the version we want.
                let dir = fm.temporaryDirectory.appendingPathComponent("nib-update-\(version)")
                try? fm.removeItem(at: dir)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-xk", tmp.path, dir.path]
                try? unzip.run()
                unzip.waitUntilExit()
                let app = dir.appendingPathComponent("Nib.app")
                let plist = app.appendingPathComponent("Contents/Info.plist")
                if unzip.terminationStatus == 0,
                   let info = NSDictionary(contentsOf: plist),
                   info["CFBundleShortVersionString"] as? String == version {
                    staged = app.path
                } else {
                    failure = "downloaded bundle failed verification"
                }
            } else {
                failure = "download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let failure {
                        self.settingsPopover?.setDownload(id: progressID, progress: 0, error: failure)
                        return
                    }
                    guard let staged else { return }
                    self.settingsPopover?.setDownload(id: progressID, progress: 1, done: true)
                    print("⬆️ update \(version) staged — swapping on exit")
                    self.relaunch(swapping: staged, into: bundlePath)
                }
            }
        }
        var lastPercent = -1
        modelDownloadProgress = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let percent = Int(p.fractionCompleted * 100)
            guard percent != lastPercent else { return }
            lastPercent = percent
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.settingsPopover?.setDownload(id: progressID, progress: p.fractionCompleted)
                }
            }
        }
        task.resume()
    }

    /// Detach a script that waits for this process to exit, swaps the bundle,
    /// clears quarantine, and relaunches — then quit.
    private func relaunch(swapping staged: String, into dest: String) {
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(dest)"
        ditto "\(staged)" "\(dest)"
        xattr -dr com.apple.quarantine "\(dest)" 2>/dev/null
        open "\(dest)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        try? p.run()
        llmServer.stop()
        taskServers.values.forEach { $0.stop() }
        NSApp.terminate(nil)
    }

    /// Open the logs folder (app log + llama-server log) in Finder.
    private func openLlamaLog() {
        try? FileManager.default.createDirectory(
            at: LLMPaths.logsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(LLMPaths.logsDir)
    }

    /// Push current state (enabled + accessibility + LLM) into the settings UI.
    private func pushSettingsState() {
        let trusted = AXIsProcessTrusted()
        lastSettingsTrusted = trusted
        let taskModels = Dictionary(uniqueKeysWithValues: LLMTask.allCases.map {
            ($0.rawValue, taskModelID(for: $0) ?? "default")
        })
        settingsPopover?.setState(enabled: enabled,
                                  accessibilityTrusted: trusted,
                                  llmStatus: llmStatusString(),
                                  model: LLMPaths.modelName() ?? "—",
                                  targetLanguage: targetLanguage,
                                  onboardingCompleted: LLMPaths.onboardingCompleted(),
                                  explainFixes: explainFixes,
                                  deepCheck: deepCheck,
                                  blockedApps: blockedApps.map { ["id": $0.key, "name": $0.value] },
                                  currentApp: lastActiveApp.map { ["id": $0.id, "name": $0.name] },
                                  downloadedModels: downloadedModelIDs(),
                                  customModels: customModelFiles(),
                                  version: appVersion,
                                  taskModels: taskModels)
    }

    private func handleSettingsMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            pushSettingsState()
        case "resize":
            if let width = (body["width"] as? NSNumber)?.doubleValue,
               let height = (body["height"] as? NSNumber)?.doubleValue {
                settingsPopover?.resize(toContentWidth: CGFloat(width), height: CGFloat(height))
            }
        case "setEnabled":
            enabled = (body["value"] as? NSNumber)?.boolValue ?? true
            if enabled {
                lastSignature = ""
                tick()
            } else {
                clearOverlay()
            }
        case "setTargetLanguage":
            if let value = body["value"] as? String, !value.isEmpty {
                targetLanguage = value
                UserDefaults.standard.set(value, forKey: "targetLanguage")
            }
        case "setExplainFixes":
            explainFixes = (body["value"] as? NSNumber)?.boolValue ?? true
            UserDefaults.standard.set(explainFixes, forKey: "explainFixes")
        case "listApps":
            sendInstalledApps()
        case "setAppBlocked":
            if let id = body["id"] as? String, let blocked = body["blocked"] as? NSNumber {
                if blocked.boolValue {
                    blockedApps[id] = (body["name"] as? String) ?? id
                    clearOverlay()
                } else {
                    blockedApps.removeValue(forKey: id)
                }
                UserDefaults.standard.set(blockedApps, forKey: "blockedApps")
                lastSignature = ""
                pushSettingsState()
            }
        case "unblockApp":
            if let id = body["id"] as? String {
                blockedApps.removeValue(forKey: id)
                UserDefaults.standard.set(blockedApps, forKey: "blockedApps")
                lastSignature = ""
                pushSettingsState()
            }
        case "setDeepCheck":
            deepCheck = (body["value"] as? NSNumber)?.boolValue ?? false
            UserDefaults.standard.set(deepCheck, forKey: "deepCheck")
            // Re-evaluate the field with the new mode.
            lastSignature = ""
            checkedValueHash = 0
        case "sandbox":
            // The sandbox reads/writes its own textarea through the webview DOM
            // (JS), not AX — WebKit doesn't expose our own webview's text to AX.
            sandboxActive = (body["active"] as? NSNumber)?.boolValue ?? false
            if sandboxActive {
                // The model picker (NSOpenPanel) left the panel non-key; re-key it
                // and focus the web content so the textarea's autofocus takes.
                settingsPopover?.focusWebContent()
            } else {
                hidePill()
                if popoverMode == .rephrase { popoverPanel.orderOut(nil); popoverMode = .none }
            }
        case "sandboxRephrase":
            if sandboxActive { openSandboxCard() }
        case "sandboxGrammar":
            if sandboxActive,
               let original = body["original"] as? String,
               let corrected = body["corrected"] as? String,
               let x = (body["x"] as? NSNumber)?.doubleValue,
               let y = (body["y"] as? NSNumber)?.doubleValue,
               let w = (body["w"] as? NSNumber)?.doubleValue,
               let h = (body["h"] as? NSNumber)?.doubleValue,
               let rect = settingsPopover?.domRectToScreen(x: x, y: y, w: w, h: h) {
                openSandboxGrammarCard(original: original, corrected: corrected, rect: rect)
            }
        case "openAccessibility":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case "chooseModel":
            chooseModel()
        case "downloadModel":
            if let id = body["id"] as? String { startModelDownload(id: id) }
        case "selectModel":
            if let id = body["id"] as? String { selectModel(id: id) }
        case "setTaskModel":
            if let taskName = body["task"] as? String, let task = LLMTask(rawValue: taskName) {
                let id = body["id"] as? String
                if let id, id != "default" {
                    UserDefaults.standard.set(id, forKey: "taskModel.\(task.rawValue)")
                } else {
                    UserDefaults.standard.removeObject(forKey: "taskModel.\(task.rawValue)")
                }
                _ = server(for: task)   // warm the newly-assigned model
                pruneTaskServers()
                // New grammar model → re-run detection against it.
                if task == .grammar { lastSignature = ""; checkedValueHash = 0 }
                pushSettingsState()
            }
        case "cancelDownload":
            cancelModelDownload()
        case "dragWindow":
            settingsPopover?.beginDrag()
        case "closeSettings":
            // Tapping Done on the "all set" screen (or closing a completed
            // onboarding) marks it done so it won't reappear on next launch.
            if settingsPopover?.isOnboarding == true && isSetUp {
                LLMPaths.setOnboardingCompleted(true)
            }
            settingsPopover?.close()
        case "checkForUpdates":
            checkForUpdates()
        case "openURL":
            if let s = body["url"] as? String, let url = URL(string: s),
               url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        case "installUpdate":
            if let version = body["version"] as? String {
                let page = body["url"] as? String ?? "https://github.com/taranek/nib/releases/latest"
                installUpdate(version: version, pageURL: page)
            }
        case "openLogs":
            openLlamaLog()
        case "openModelsFolder":
            try? FileManager.default.createDirectory(
                at: LLMPaths.modelsDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(LLMPaths.modelsDir)
        case "quit":
            llmServer.stop()
            taskServers.values.forEach { $0.stop() }
            NSApp.terminate(nil)
        default:
            break
        }
    }

    // MARK: - Clearing & geometry

    private func clearIfNeeded() {
        // The pill tracks its own state (independent of the detection signature),
        // so always re-check it — otherwise a stale pill can outlive its field.
        hidePill()
        if lastSignature.isEmpty { return }
        clearOverlay()
    }

    /// Tear down all on-screen UI and reset detection state.
    private func clearOverlay() {
        lastSignature = ""
        lastHighlightsKey = ""
        flagged = []
        view.update(highlights: [])
        pillPanel.hide()
        pillRect = nil
        popoverPanel.orderOut(nil)
        popoverMode = .none
        activeWord = nil
        hoveredID = nil
        activeElement = nil
    }

    /// A resolved rect is trustworthy only if it sits within the field
    /// (contenteditable sometimes returns valid-looking but off-field rects).
    /// Convert an AX rect to Cocoa space, rejecting answers that describe the
    /// field rather than the text in it. Chromium replies to geometry queries it
    /// can't resolve with the element's own box, which would otherwise strand
    /// the pill at the middle of the field instead of beside the caret's line.
    /// The tell is that it matches the field exactly — real text is inset from
    /// it, even a select-all — so size alone can't be the test: a genuine
    /// multi-line selection is legitimately tall.
    private func lineRect(_ axRect: CGRect?, _ field: CGRect) -> CGRect? {
        guard let axRect else { return nil }
        let r = toCocoa(axRect)
        guard r.height > 0 else { return nil }
        let slop: CGFloat = 2
        let isFieldBox = abs(r.minX - field.minX) <= slop && abs(r.maxX - field.maxX) <= slop
            && abs(r.minY - field.minY) <= slop && abs(r.maxY - field.maxY) <= slop
        guard !isFieldBox else { return nil }
        // Nor anything outside the field (the web-area box is another stand-in
        // Chromium hands back).
        guard isInsideField(r, field) else { return nil }
        return r
    }

    private func isInsideField(_ rect: CGRect, _ field: CGRect) -> Bool {
        guard rect.height > 0 else { return false }
        let slack: CGFloat = 8
        return rect.minY >= field.minY - slack
            && rect.maxY <= field.maxY + slack
            && rect.minX >= field.minX - slack
            && rect.minX <= field.maxX
    }

    /// Convert Harper lints into sentence-level corrections (the shape the
    /// whole downstream pipeline — diffing, rects, the card, write-back —
    /// already speaks): group lints by containing sentence and apply each
    /// lint's first suggestion right-to-left.
    private func corrections(fromLints lints: [HarperLint], in text: String) -> [SentenceCorrection] {
        let ns = text as NSString
        var bySentence: [NSRange: [HarperLint]] = [:]
        for lint in lints where !lint.suggestions.isEmpty {
            guard lint.range.location + lint.range.length <= ns.length else { continue }
            let sentence = sentenceRange(covering: lint.range, in: ns)
            bySentence[sentence, default: []].append(lint)
        }
        var out: [SentenceCorrection] = []
        for (sentence, sentenceLints) in bySentence {
            let original = ns.substring(with: sentence)
            var corrected = original as NSString
            for lint in sentenceLints.sorted(by: { $0.range.location > $1.range.location }) {
                let rel = NSRange(location: lint.range.location - sentence.location,
                                  length: lint.range.length)
                guard rel.location >= 0,
                      rel.location + rel.length <= corrected.length else { continue }
                corrected = corrected.replacingCharacters(in: rel, with: lint.suggestions[0]) as NSString
            }
            let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCorrected = (corrected as String).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOriginal != trimmedCorrected {
                out.append(SentenceCorrection(original: trimmedOriginal, corrected: trimmedCorrected))
            }
        }
        return out
    }

    /// Deep check: after Harper's rule pass, run the LLM over the same text in
    /// the background and merge its sentence fixes on top (LLM supersedes
    /// Harper for a sentence both touched — its fix includes the mechanical
    /// corrections anyway). Trailing, never blocking: squiggles from rules are
    /// already on screen when this starts.
    private func runDeepCheck(value: String, text: String, token: Int,
                              appName: String?, base: [SentenceCorrection]) {
        let grammarServer = server(for: .grammar)
        guard grammarServer.status == .ready else { return }
        let grammarFile = taskModelFile(for: .grammar)
        let quirks = ModelManifest.byFile(grammarFile)?.validate
        let client = LLMClient(chatURL: grammarServer.chatURL,
                               echoMarkers: quirks?.echoMarkers ?? [],
                               maxGrowth: quirks?.maxGrowth ?? 2.0)
        grammarTask?.cancel()
        grammarTask = Task { [weak self] in
            let llm = await client.corrections(in: text)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                let current = AX.focusedElement().flatMap { AX.string($0, kAXValueAttribute) }
                guard current == value, self.checkedValueHash == token else { return }
                var bySentence = Dictionary(base.map { ($0.original, $0) },
                                            uniquingKeysWith: { _, new in new })
                for correction in llm { bySentence[correction.original] = correction }
                let merged = Array(bySentence.values)
                guard merged.count != base.count || llm.count != 0 else { return }
                print("🔬 deep check: +\(merged.count - base.count) sentence fix(es)")
                self.currentCorrections = merged
                self.renderSentenceFixes(merged, fullText: text, appName: appName)
            }
        }
    }

    /// Split a range into per-line subranges at hard newlines (empty segments
    /// dropped) so multi-line ranges don't render as one union box.
    private static func splitAtNewlines(_ range: NSRange, in ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = range.location
        let end = range.location + range.length
        var i = start
        while i < end {
            if ns.character(at: i) == 10 {
                if i > start { out.append(NSRange(location: start, length: i - start)) }
                start = i + 1
            }
            i += 1
        }
        if end > start { out.append(NSRange(location: start, length: end - start)) }
        return out
    }

    /// Expand a range to the whole sentence(s) it overlaps: back to the previous
    /// sentence terminator, forward to the next one. Matches the in-page logic.
    private func sentenceRange(covering range: NSRange, in ns: NSString) -> NSRange {
        // Newlines bound sentences too — chat text often has no .!? at all, and
        // without this the expansion swallows the entire field.
        let enders = CharacterSet(charactersIn: ".!?\n")
        func isEnder(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let s = Unicode.Scalar(ns.character(at: i)) else { return false }
            return enders.contains(s)
        }
        func isSpace(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length else { return false }
            return ns.character(at: i) <= 32
        }
        var start = range.location
        while start > 0, !isEnder(start - 1) { start -= 1 }
        while start < range.location, isSpace(start) { start += 1 }
        var end = range.location + range.length
        while end < ns.length, !isEnder(end - 1) { end += 1 }
        // Don't let the range end on newline(s) — write-back would eat the
        // paragraph break (never shrink past the original selection).
        while end > range.location + range.length, ns.character(at: end - 1) == 10 { end -= 1 }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// A rect safe to draw a highlight for: inside the field and not absurdly
    /// large (some fields return document- or screen-sized rects).
    private func isSaneRect(_ rect: CGRect, in field: CGRect) -> Bool {
        isInsideField(rect, field)
            && rect.width > 0 && rect.width <= field.width + 8
            && rect.height <= 120
    }

    /// Resolve one character range to a screen rect (view coords) via
    /// AXBoundsForRange. Works on native controls and real <textarea>s.
    private func screenRect(for ns: NSRange, in element: AXUIElement) -> CGRect? {
        AX.bounds(of: CFRange(location: ns.location, length: ns.length), in: element).map(toCocoa)
    }

    /// AX gives global coords with a top-left origin; AppKit views use
    /// bottom-left. Flip against the primary screen's height. (Single-screen
    /// PoC — multi-monitor needs per-screen mapping.)
    /// The union of every display, in global (bottom-left origin) coords.
    private static func desktopFrame() -> NSRect {
        NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
    }

    /// Resize the overlay after a display change, and re-render at the new origin.
    private func fitOverlayToDesktop() {
        let desktop = Self.desktopFrame()
        guard desktop != window.frame else { return }
        window.setFrame(desktop, display: true)
        view.frame = NSRect(origin: .zero, size: desktop.size)
        print("🖥️ displays changed — overlay now \(Int(desktop.width))×\(Int(desktop.height))")
        lastHighlightsKey = ""          // force a redraw at the new origin
        applyDetection(flagged, element: activeElement)
    }

    private func toCocoa(_ axRect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let y = primaryHeight - axRect.origin.y - axRect.size.height
        return CGRect(x: axRect.origin.x, y: y, width: axRect.size.width, height: axRect.size.height)
    }
}
