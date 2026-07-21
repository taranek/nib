# Nib

A local-first writing assistant for macOS. Nib lives in the menu bar, watches
the text field you're typing in — in **any** app — and offers grammar fixes and
rewrites powered entirely by a **local LLM** (llama.cpp). Your text never
leaves your Mac.

> Internal code name: `loco` — the Swift package, binary, and `LOCO_*` env vars
> keep that name; everything user-facing is **Nib**.

## What it does

- **Inline grammar checking** — mistakes get a squiggle right in the app you're
  typing in (via the macOS Accessibility API + a transparent, click-through
  overlay). Hover a squiggle for the fix.
- **Explained fixes** — each correction names the grammar rule in plain words
  ("Verb form after 'can'"), with wrong → right examples on demand. Toggleable
  in Settings.
- **Rewrite card** — select text anywhere and press <kbd>⌘</kbd><kbd>`</kbd>
  (or hover the pill) for Rephrase / Shorten / Translate tabs, quick-edit chips,
  and a composer for custom instructions.
- **Local models** — pick from a curated catalog (Gemma 4 E2B recommended,
  Qwen 2.5 3B, Llama 3.2 3B) downloaded straight from Hugging Face, or supply
  your own `.gguf`. Served by a bundled `llama-server`.
- **First-run onboarding** — guided setup (Accessibility → model) plus a
  hands-on sandbox to try both interactions before using them for real.

## Requirements

- macOS 13+, Apple Silicon (the bundled `llama-server` is arm64)
- ~3 GB disk for a model (downloaded on first run, not bundled)
- Accessibility permission (prompted on first launch)

## Install

Grab `Nib.dmg` from [Releases](https://github.com/taranek/nib/releases), drag
**Nib** into Applications.

The build isn't notarized yet, so first launch shows *"Apple could not verify
'Nib' is free of malware"*. To open it anyway:

1. In the dialog, click **Done** (not "Move to Trash").
2. **System Settings → Privacy & Security**, scroll down to *"Nib" was blocked*
   → **Open Anyway**, then confirm.

Or from a terminal: `xattr -dr com.apple.quarantine /Applications/Nib.app`

## Development

The UI is a React app rendered in `WKWebView`s; the host is a Swift menu-bar
agent. One command runs both with hot reload:

```sh
./dev.sh        # Vite (HMR) + Swift rebuild-on-save + llama-server kept warm
```

Or by hand:

```sh
cd web && npm install && npm run dev    # terminal A — http://localhost:5173
swift run loco                          # terminal B — the native agent
```

First launch prompts for Accessibility: **System Settings → Privacy &
Security → Accessibility**, enable the binary (or your terminal — macOS often
attributes CLI tools to their parent), then re-run.

### Environment overrides

| Variable | Purpose |
|---|---|
| `LOCO_WEB_URL` | Where the web UI loads from (default: bundled `Resources/web`, dev.sh sets `http://localhost:5173`) |
| `LOCO_MODEL` | Path to a `.gguf` model (overrides the saved/downloaded one) |
| `LOCO_LLAMA_SERVER` | Path to a `llama-server` binary |
| `LOCO_DEBUG` | Verbose logging |

### Useful scripts

```sh
./scripts/fresh-onboarding.sh   # relaunch in a fresh first-run state (replays onboarding)
./scripts/package.sh            # build release/Nib.app + drag-to-install DMG + zip
```

App data lives in `~/Library/Application Support/Nib/` (`bin/llama-server`,
`models/*.gguf`, `state.json` for the onboarding flag).

## Architecture

| Piece | Where |
|---|---|
| Controller: focus watching, detection, cards, settings | `Sources/loco/Controller/AppController.swift` |
| Accessibility helpers (`AXBoundsForRange`, web-area checks) | `Sources/loco/Accessibility/AX.swift` |
| Click-through overlay (squiggles + pill) | `Sources/loco/Overlay/` |
| llama-server lifecycle + paths | `Sources/loco/LLM/LLM.swift` |
| Card + settings/onboarding panels (`WKWebView` hosts) | `Sources/loco/UI/` |
| React UI: card, settings, onboarding, model catalog | `web/src/` |
| Swift ⇄ JS contract | `web/src/bridge.ts` |

Detection is event-driven (`AXObserver` for focus/value/selection, workspace
notifications for app switches) with a slow safety poll. Browser page content
is read via the DOM bridge or AX fallback; browser chrome (address bar) is
excluded by requiring an `AXWebArea` ancestor.
