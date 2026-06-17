import Cocoa
import ApplicationServices
import WebKit

// MARK: - Controller
//
// Wires everything together: watches the focused field, runs grammar checks
// through the local LLM (debounced + async), maps each flagged phrase to an
// on-screen rect, draws highlights, and drives the hover card + settings popover.

@MainActor
final class AppController: NSObject {
    private var window: OverlayWindow!
    private var view: OverlayView!
    private var popoverPanel: PopoverPanel!
    private let browser = BrowserBridge()
    static let debug = ProcessInfo.processInfo.environment["LOCO_DEBUG"] != nil
    private var timer: Timer?
    private var mouseMonitor: Any?

    // Menu bar presence + the settings popover it opens.
    private var statusItem: NSStatusItem?
    private var settingsPopover: SettingsPopover?
    private var enabled = true

    // The field + flagged words the UI currently targets.
    private var activeElement: AXUIElement?
    private var activeBrowserAppName: String?
    private var flagged: [FlaggedWord] = []

    // The word whose card is open, and the word the cursor is currently over.
    private var activeWord: FlaggedWord?
    private var hoveredID: String?
    private var hideHoverTimer: Timer?

    // Words the user dismissed (by id) — cleared whenever the text changes,
    // since edits shift occurrence indices.
    private var dismissed = Set<String>()

    // Cache so we only re-evaluate when the text/frame changes.
    private var lastSignature: String = ""
    private var lastValueHash: Int = 0
    private var lastHighlightsKey: String = ""   // skip redundant overlay redraws

    // Local LLM grammar checking.
    private let llmServer = LLMServer()
    private var llmClient: LLMClient?
    private var llmReady = false
    private var currentCorrections: [(wrong: String, fix: String)] = []
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
        if !ensureAccessibilityPermission() {
            print("""
            ⏳ Accessibility permission required.
               1. Open System Settings → Privacy & Security → Accessibility
               2. Enable the entry for this binary (or your terminal app)
               3. Re-run:  swift run loco
            """)
        }

        let screen = NSScreen.screens.first ?? NSScreen.main!
        window = OverlayWindow(screenFrame: screen.frame)
        view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        window.orderFrontRegardless()

        popoverPanel = PopoverPanel(url: Self.webURL())
        popoverPanel.onEnter = { [weak self] in self?.cancelHidePopover() }
        popoverPanel.onExit = { [weak self] in self?.scheduleHidePopover() }
        popoverPanel.onMessage = { [weak self] body in self?.handleWebMessage(body) }

        setupStatusItem()
        startLLM()

        print("✅ loco running. Grammar checked by a local LLM; hover a highlight to apply a fix.")
        print("   Card UI from: \(Self.webURL().absoluteString)\n")

        // Hover detection over the click-through overlay: a global mouse monitor
        // (fires for other apps; our accessory app is never frontmost) checks the
        // cursor against the flagged-word rects without consuming the events.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseMove() }
        }

        // Event-driven: react to focus/value changes via AXObserver, and to app
        // switches via NSWorkspace. A slow safety poll backstops anything not
        // delivered as a notification (e.g. scroll, window moves).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        rebuildObservers()

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
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

        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }

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

    /// Observe value changes on the currently focused element.
    private func attachToFocusedElement() {
        guard let observer = axObserver else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let old = observedElement {
            AXObserverRemoveNotification(observer, old, kAXValueChangedNotification as CFString)
        }
        observedElement = AX.focusedElement()
        if let element = observedElement {
            AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
        }
    }

    private func handleAXNotification(_ notification: String) {
        if notification == kAXFocusedUIElementChangedNotification as String {
            attachToFocusedElement()
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
        guard enabled else { return }

        // Skip detection while our own UI is in front — nothing to correct there,
        // and not redrawing the full-screen overlay keeps the popover smooth.
        if settingsPopover?.isShown == true || frontmostIsSelf() {
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
            renderCorrections(currentCorrections, appName: appName)
        }
    }

    /// Debounce the grammar check so fast typing doesn't fire a request per key.
    private func scheduleRecheck(value: String, appName: String?) {
        grammarDebounce?.invalidate()
        grammarDebounce = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck(value: value, appName: appName) }
        }
    }

    /// Produce corrections for the focused field (LLM if ready, else the
    /// dictionary), then locate + render them. `value` is the AX-derived text that
    /// triggered this pass (used for the change token + staleness check); for
    /// browsers we validate the DOM text so phrases match what `locate` searches.
    private func recheck(value: String, appName: String?) {
        let token = value.hashValue
        let text = appName.flatMap { browser.focusedText(appName: $0) } ?? value
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            currentCorrections = []
            checkedValueHash = token
            applyDetection([], element: AX.focusedElement())
            return
        }

        if llmReady, let client = llmClient {
            print("📝 validating focused input (\(text.count) chars)…")
            grammarTask?.cancel()
            grammarTask = Task { [weak self] in
                let corrections = await client.check(text: text)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    print("   → \(corrections.count) suggestion(s)")
                    // Only apply if the field still holds the text we checked.
                    let current = AX.focusedElement().flatMap { AX.string($0, kAXValueAttribute) }
                    guard current == value else { print("   (stale — field changed)"); return }
                    self.currentCorrections = corrections.map { (wrong: $0.wrong, fix: $0.fix) }
                    self.checkedValueHash = token
                    self.renderCorrections(self.currentCorrections, appName: appName)
                }
            }
        } else {
            var pairs: [(wrong: String, fix: String)] = []
            var seen = Set<String>()
            for hit in Linter.words(in: text) where seen.insert(hit.word).inserted {
                pairs.append((wrong: hit.word, fix: hit.replacement))
            }
            currentCorrections = pairs
            checkedValueHash = token
            renderCorrections(pairs, appName: appName)
        }
    }

    /// Map each correction's `wrong` phrase to an on-screen rect and render.
    /// Browser → in-page DOM search; native → AXBoundsForRange over the value.
    private func renderCorrections(_ pairs: [(wrong: String, fix: String)], appName: String?) {
        guard let element = AX.focusedElement(), let axFrame = AX.frame(element) else {
            applyDetection([], element: nil); return
        }
        let fieldBox = toCocoa(axFrame)
        var words: [FlaggedWord] = []

        if let appName, let hits = browser.locate(appName: appName, phrases: pairs.map { $0.wrong }) {
            activeBrowserAppName = appName
            for h in hits where pairs.indices.contains(h.phraseIndex) {
                let pair = pairs[h.phraseIndex]
                let rect = CGRect(x: fieldBox.minX + h.x,
                                  y: fieldBox.maxY - h.y - h.height,
                                  width: h.width, height: h.height)
                guard isInsideField(rect, fieldBox) else { continue }
                words.append(FlaggedWord(word: pair.wrong, replacement: pair.fix,
                                         message: message(pair.wrong, pair.fix),
                                         category: "Grammar", rect: rect, range: nil,
                                         key: pair.wrong, occurrence: h.occurrence))
            }
        } else {
            activeBrowserAppName = nil
            let ns = (AX.string(element, kAXValueAttribute) ?? "") as NSString
            for pair in pairs {
                var from = 0
                var occ = 0
                while from <= ns.length {
                    let r = ns.range(of: pair.wrong, options: [],
                                     range: NSRange(location: from, length: ns.length - from))
                    if r.location == NSNotFound { break }
                    from = r.location + max(1, r.length)
                    guard isWordBounded(r, in: ns) else { continue }
                    if let rect = screenRect(for: r, in: element), isSaneRect(rect, in: fieldBox) {
                        words.append(FlaggedWord(word: pair.wrong, replacement: pair.fix,
                                                 message: message(pair.wrong, pair.fix),
                                                 category: "Grammar", rect: rect, range: r,
                                                 key: pair.wrong, occurrence: occ))
                    }
                    occ += 1
                }
            }
        }

        words = words.filter { !dismissed.contains($0.id) }
        if !pairs.isEmpty {
            print("   highlighted \(words.count)/\(pairs.count) on \(appName ?? "native")")
        }
        applyDetection(words, element: element)
    }

    /// Commit a set of flagged words to the overlay (and close a stale card).
    private func applyDetection(_ words: [FlaggedWord], element: AXUIElement?) {
        activeElement = element
        flagged = words
        let highlights = words.map { Highlight(rect: $0.rect, color: .systemRed) }
        let key = highlights
            .map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)),\(Int($0.rect.width))" }
            .joined(separator: ";")
        if key != lastHighlightsKey {
            lastHighlightsKey = key
            view.update(highlights: highlights)
        }
        if let aw = activeWord, !words.contains(where: { $0.id == aw.id }) {
            popoverPanel.orderOut(nil)
            activeWord = nil
            hoveredID = nil
        }
    }

    private func message(_ wrong: String, _ fix: String) -> String {
        "“\(wrong)” → “\(fix)”"
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

    /// Driven by the global mouse monitor: open the card for the word under the
    /// cursor, keep it open over the word or the card, hide otherwise.
    private func handleMouseMove() {
        let p = NSEvent.mouseLocation

        if popoverPanel.isVisible, popoverPanel.frame.insetBy(dx: -4, dy: -4).contains(p) {
            cancelHidePopover()
            return
        }

        if let hit = flagged.first(where: { $0.rect.insetBy(dx: -2, dy: -3).contains(p) }) {
            cancelHidePopover()
            if hit.id != hoveredID {
                hoveredID = hit.id
                showCard(for: hit)
            }
        } else if hoveredID != nil {
            hoveredID = nil
            scheduleHidePopover()
        }
    }

    private func showCard(for word: FlaggedWord) {
        activeWord = word
        popoverPanel.setSuggestion(word)
        // Anchor the card's top-left just below the word, growing downward.
        popoverPanel.present(anchor: NSPoint(x: word.rect.minX, y: word.rect.minY - 6))
    }

    private func scheduleHidePopover() {
        hideHoverTimer?.invalidate()
        hideHoverTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.popoverPanel.orderOut(nil)
                self?.activeWord = nil
                self?.hoveredID = nil
            }
        }
    }

    private func cancelHidePopover() {
        hideHoverTimer?.invalidate()
        hideHoverTimer = nil
    }

    // MARK: - Messages from the React card

    private func handleWebMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            if let word = activeWord { popoverPanel.setSuggestion(word) }
        case "resize":
            if let width = (body["width"] as? NSNumber)?.doubleValue,
               let height = (body["height"] as? NSNumber)?.doubleValue {
                popoverPanel.resize(toContentWidth: CGFloat(width), height: CGFloat(height))
            }
        case "apply":
            if let word = activeWord { apply(word) }
            finishCard()
        case "dismiss":
            if let word = activeWord { dismissed.insert(word.id) }
            finishCard()
        default:
            break
        }
    }

    /// Apply one fix: browser → DOM replace via JS; native → AX range replace.
    private func apply(_ word: FlaggedWord) {
        if let appName = activeBrowserAppName {
            browser.replace(appName: appName, phrase: word.key,
                            occurrence: word.occurrence, fix: word.replacement)
        } else if let element = activeElement, let range = word.range {
            var cf = CFRange(location: range.location, length: range.length)
            if let axRange = AXValueCreate(.cfRange, &cf) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
                AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                             word.replacement as CFString)
            }
        }
    }

    private func finishCard() {
        popoverPanel.orderOut(nil)
        activeWord = nil
        hoveredID = nil
        lastSignature = ""       // force a fresh evaluation on the next tick
        checkedValueHash = 0     // the text changed — recheck rather than re-locate
    }

    /// Force a Chromium/Electron app to build and expose its accessibility tree.
    /// Setting `AXManualAccessibility` (and the legacy `AXEnhancedUserInterface`)
    /// on the app element is the documented switch ATs use. Done once per PID.
    private func enableBrowserAccessibilityIfNeeded(for element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              !a11yEnabledPids.contains(pid),
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

    /// Put a small icon in the menu bar; clicking it opens the settings popover.
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "checkmark.bubble", accessibilityDescription: "loco") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "loco"
            }
            button.toolTip = "loco — writing suggestions"
            button.target = self
            button.action = #selector(openSettings)
        }
        statusItem = item
    }

    @objc private func openSettings() {
        guard let button = statusItem?.button else { return }
        if settingsPopover == nil {
            let popover = SettingsPopover(url: Self.settingsURL())
            popover.onMessage = { [weak self] body in self?.handleSettingsMessage(body) }
            settingsPopover = popover
        }
        // Toggle: clicking the icon again closes it.
        if settingsPopover?.isShown == true {
            settingsPopover?.close()
            return
        }
        settingsPopover?.show(relativeTo: button)
        pushSettingsState()
    }

    /// Where the React UI comes from. Resolution order:
    ///   1. LOCO_WEB_URL (e.g. http://localhost:5173 for live web dev)
    ///   2. the built web/dist (works with no dev server — the default)
    ///   3. localhost:5173 as a last resort
    private static func webURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["LOCO_WEB_URL"],
           let url = URL(string: raw) {
            return url
        }
        let dist = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("web/dist/index.html")
        if FileManager.default.fileExists(atPath: dist.path) {
            return dist
        }
        return URL(string: "http://localhost:5173")!
    }

    /// The web UI in settings mode (same bundle, `#settings` hash).
    private static func settingsURL() -> URL {
        let base = webURL()
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.fragment = "settings"
        return comps?.url ?? base
    }

    /// Push current state (enabled + accessibility + LLM) into the settings UI.
    private func pushSettingsState() {
        settingsPopover?.setState(enabled: enabled,
                                  accessibilityTrusted: AXIsProcessTrusted(),
                                  llmStatus: llmStatusString(),
                                  model: LLMPaths.modelName() ?? "—")
    }

    private func handleSettingsMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            pushSettingsState()
        case "setEnabled":
            enabled = (body["value"] as? NSNumber)?.boolValue ?? true
            if enabled {
                lastSignature = ""
                tick()
            } else {
                clearOverlay()
            }
        case "openAccessibility":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case "quit":
            llmServer.stop()
            NSApp.terminate(nil)
        default:
            break
        }
    }

    // MARK: - Clearing & geometry

    private func clearIfNeeded() {
        if lastSignature.isEmpty { return }
        clearOverlay()
    }

    /// Tear down all on-screen UI and reset detection state.
    private func clearOverlay() {
        lastSignature = ""
        lastHighlightsKey = ""
        flagged = []
        view.update(highlights: [])
        popoverPanel.orderOut(nil)
        activeWord = nil
        hoveredID = nil
        activeElement = nil
    }

    /// A resolved rect is trustworthy only if it sits within the field
    /// (contenteditable sometimes returns valid-looking but off-field rects).
    private func isInsideField(_ rect: CGRect, _ field: CGRect) -> Bool {
        guard rect.height > 0 else { return false }
        let slack: CGFloat = 8
        return rect.minY >= field.minY - slack
            && rect.maxY <= field.maxY + slack
            && rect.minX >= field.minX - slack
            && rect.minX <= field.maxX
    }

    /// Whether a match sits on word boundaries (so "o" doesn't match inside
    /// another word), matching the in-page locate logic.
    private func isWordBounded(_ r: NSRange, in ns: NSString) -> Bool {
        let alnum = CharacterSet.alphanumerics
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length else { return false }
            guard let scalar = Unicode.Scalar(ns.character(at: i)) else { return false }
            return alnum.contains(scalar)
        }
        return !isWord(r.location - 1) && !isWord(r.location + r.length)
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
    private func toCocoa(_ axRect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let y = primaryHeight - axRect.origin.y - axRect.size.height
        return CGRect(x: axRect.origin.x, y: y, width: axRect.size.width, height: axRect.size.height)
    }
}
