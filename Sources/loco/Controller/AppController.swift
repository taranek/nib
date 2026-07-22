import Cocoa
import ApplicationServices
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
        print("▸ status item installed")

        // Pre-create the settings popover so its web UI preloads before the first
        // open (otherwise the panel shows empty on launch).
        let popover = SettingsPopover(url: Self.webURL())
        popover.onMessage = { [weak self] body in self?.handleSettingsMessage(body) }
        settingsPopover = popover

        startLLM()

        print("✅ Nib running. Grammar checked by a local LLM; hover a highlight to apply a fix.")
        print("   Card UI from: \(Self.webURL().absoluteString)\n")

        // Hover detection over the click-through overlay: a global mouse monitor
        // (fires for other apps; our accessory app is never frontmost) checks the
        // cursor against the flagged-word rects without consuming the events.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseMove() }
        }

        registerRephraseHotKey()

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
        observedElement = AX.focusedElement()
        if let element = observedElement {
            AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
            AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, refcon)
        }
    }

    private func handleAXNotification(_ notification: String) {
        if notification == kAXFocusedUIElementChangedNotification as String {
            attachToFocusedElement()
        }
        if notification == kAXSelectedTextChangedNotification as String {
            scheduleSelectionUpdate()
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
        if appName != nil, !AX.isInWebArea(element) { clearIfNeeded(); return }

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
        guard llmReady, let client = llmClient,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            currentCorrections = []
            currentFullText = text
            checkedValueHash = token
            applyDetection([], element: AX.focusedElement())
            return
        }

        print("📝 validating focused input (\(text.count) chars)…")
        grammarTask?.cancel()
        grammarTask = Task { [weak self] in
            let corrections = await client.corrections(in: text)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                print("   → \(corrections.count) sentence fix(es)")
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
        struct Pending { let range: NSRange; let original: String; let corrected: String }
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
            if let rs = browser.rects(appName: appName, ranges: pendings.map { ($0.range.location, $0.range.length) }) {
                for rr in rs where pendings.indices.contains(rr.index) {
                    let p = pendings[rr.index]
                    let rect = CGRect(x: fieldBox.minX + rr.x, y: fieldBox.maxY - rr.y - rr.height,
                                      width: rr.width, height: rr.height)
                    guard isInsideField(rect, fieldBox) else { continue }
                    words.append(FlaggedWord(rect: rect, original: p.original, corrected: p.corrected,
                                             range: nil, sentenceID: p.original))
                }
            }
        } else {
            activeBrowserAppName = nil
            for p in pendings {
                guard let rect = screenRect(for: p.range, in: element), isSaneRect(rect, in: fieldBox) else { continue }
                let sentence = ns.range(of: p.original)
                words.append(FlaggedWord(rect: rect, original: p.original, corrected: p.corrected,
                                         range: sentence.location != NSNotFound ? sentence : nil,
                                         sentenceID: p.original))
            }
        }

        words = words.filter { !dismissed.contains($0.id) }
        if !corrections.isEmpty { print("   highlighted \(words.count) on \(appName ?? "native")") }
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

        // Rephrase pill takes priority — it sits next to the selection.
        if let pill = pillRect, pill.insetBy(dx: -6, dy: -6).contains(p) {
            cancelHidePopover()
            if popoverMode != .rephrase { showRephrase() }
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
        popoverPanel.setCard([
            "mode": "grammar",
            "original": word.original,
            "result": word.corrected,
            "styles": [],
            // The card fetches a friendly "why" explanation for the fix.
            "llmUrl": llmServer.chatURL.absoluteString,
            "ready": llmReady,
            "targetLanguage": targetLanguage,
            "explainFixes": explainFixes,
        ])
        popoverPanel.present(anchor: NSPoint(x: word.rect.minX, y: word.rect.minY - 6))
    }

    private func scheduleHidePopover() {
        hideHoverTimer?.invalidate()
        hideHoverTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
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
    private func scheduleSelectionUpdate() {
        selectionDebounce?.invalidate()
        selectionDebounce = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSelectionPill() }
        }
    }

    private func updateSelectionPill() {
        guard enabled, settingsPopover?.isShown != true, !frontmostIsSelf(),
              let element = AX.focusedElement(), let axFrame = AX.frame(element) else {
            hidePill(); return
        }
        let fieldBox = toCocoa(axFrame)
        let appName = browserAppName(for: element)

        // No rephrase pill on browser chrome (address bar etc.) either.
        if appName != nil, !AX.isInWebArea(element) { hidePill(); return }

        var text: String?
        var selRect: CGRect?
        var nativeRange: NSRange?
        // Write-back route: the browser DOM path (needs Automation) when it
        // succeeds, otherwise native AX write-back (set below to nil on fallback).
        var writeAppName = appName

        if let appName, let sel = browser.selection(appName: appName) {
            // Multi-line selection → rephrase the whole sentence(s) it sits in.
            text = (sel.multiline && !sel.sentence.isEmpty) ? sel.sentence : sel.text
            selRect = CGRect(x: fieldBox.minX + sel.x, y: fieldBox.maxY - sel.y - sel.height,
                             width: sel.width, height: sel.height)
        } else if let t = AX.string(element, kAXSelectedTextAttribute),
                  !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let cf = AX.selectedRange(element) {
            // AX fallback — works for native fields AND browsers that don't grant
            // Automation / aren't contentEditable. Write back via AX (native route).
            writeAppName = nil
            selRect = AX.bounds(of: cf, in: element).map(toCocoa)
                ?? CGRect(x: fieldBox.minX, y: fieldBox.minY, width: 1, height: fieldBox.height)
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
        }

        guard let target = text, let r = selRect,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isInsideField(r, fieldBox) else {
            hidePill(); return
        }

        rephraseText = target
        rephraseAppName = writeAppName
        rephraseElement = element
        rephraseRange = nativeRange

        // Pill in the field's left margin, vertically centered on the selection.
        let size: CGFloat = 18
        let x = max(2, fieldBox.minX - size - 4)
        let pill = CGRect(x: x, y: r.midY - size / 2, width: size, height: size)
        pillRect = pill
        view.setPill(pill)
    }

    private func hidePill() {
        guard pillRect != nil else { return }
        pillRect = nil
        view.setPill(nil)
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
        popoverPanel.setCard([
            "mode": "rewrite",
            "original": text,
            "result": "",
            "styles": Self.styleList,
            "llmUrl": llmServer.chatURL.absoluteString,
            "ready": llmReady,
            "targetLanguage": targetLanguage,
            "explainFixes": explainFixes,
        ])
        popoverPanel.present(anchor: NSPoint(x: pillRect?.minX ?? 0, y: (pillRect?.minY ?? 0) - 2))
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
            showRephrase()
            startAutoDismiss()   // mouse isn't near it — close unless engaged
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
        popoverPanel.setCard([
            "mode": "grammar",
            "original": original,
            "result": corrected,
            "styles": [],
            "llmUrl": llmServer.chatURL.absoluteString,
            "ready": llmReady,
            "targetLanguage": targetLanguage,
            "explainFixes": explainFixes,
        ])
        popoverPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        popoverPanel.present(anchor: NSPoint(x: rect.minX, y: rect.minY - 6))
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
            AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
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
        default:
            break
        }
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
            if let image = NSImage(systemSymbolName: "checkmark.bubble", accessibilityDescription: "Nib") {
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

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit Nib",
                              action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func quitFromMenu() {
        llmServer.stop()
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

    /// Curated GGUF models offered in onboarding. Keep ids in sync with CATALOG
    /// in Onboarding.tsx (which holds the display copy).
    private struct CatalogModel {
        let id: String
        let file: String
        let url: URL
    }

    private static let modelCatalog: [CatalogModel] = [
        CatalogModel(
            id: "gemma-4-e2b",
            file: "gemma-4-E2B-it-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf?download=true")!),
        CatalogModel(
            id: "qwen2.5-3b",
            file: "Qwen2.5-3B-Instruct-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf?download=true")!),
        CatalogModel(
            id: "llama-3.2-3b",
            file: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true")!),
    ]

    /// Catalog ids whose file is already on disk (no need to re-download).
    private func downloadedModelIDs() -> [String] {
        Self.modelCatalog
            .filter {
                FileManager.default.fileExists(
                    atPath: LLMPaths.modelsDir.appendingPathComponent($0.file).path)
            }
            .map(\.id)
    }

    /// Activate an already-downloaded catalog model (no download).
    private func selectModel(id: String) {
        guard let model = Self.modelCatalog.first(where: { $0.id == id }) else { return }
        let dest = LLMPaths.modelsDir.appendingPathComponent(model.file)
        guard FileManager.default.fileExists(atPath: dest.path) else { return }
        UserDefaults.standard.set(dest.path, forKey: "modelPath")
        llmReady = false
        llmServer.restart()
        pushSettingsState()
    }

    private func startModelDownload(id: String) {
        guard modelDownload == nil,
              let model = Self.modelCatalog.first(where: { $0.id == id }) else { return }
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
        settingsPopover?.setState(enabled: enabled,
                                  accessibilityTrusted: trusted,
                                  llmStatus: llmStatusString(),
                                  model: LLMPaths.modelName() ?? "—",
                                  targetLanguage: targetLanguage,
                                  onboardingCompleted: LLMPaths.onboardingCompleted(),
                                  explainFixes: explainFixes,
                                  downloadedModels: downloadedModelIDs(),
                                  version: appVersion)
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
        case "openLogs":
            openLlamaLog()
        case "quit":
            llmServer.stop()
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
        view.setPill(nil)
        pillRect = nil
        popoverPanel.orderOut(nil)
        popoverMode = .none
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

    /// Expand a range to the whole sentence(s) it overlaps: back to the previous
    /// sentence terminator, forward to the next one. Matches the in-page logic.
    private func sentenceRange(covering range: NSRange, in ns: NSString) -> NSRange {
        let enders = CharacterSet(charactersIn: ".!?")
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
    private func toCocoa(_ axRect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let y = primaryHeight - axRect.origin.y - axRect.size.height
        return CGRect(x: axRect.origin.x, y: y, width: axRect.size.width, height: axRect.size.height)
    }
}
