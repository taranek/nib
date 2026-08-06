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
  overlay). Hover a squiggle for the fix. English is checked instantly (~30ms,
  CPU-only) by [Harper](https://writewithharper.com)'s rule engine; other
  languages use the local LLM, and the optional **Deep checking** mode layers
  the LLM on top of the rules to catch errors rules can't see.
- **Explained fixes** — each correction names the grammar rule in plain words
  ("Verb form after 'can'"), with wrong → right examples on demand. Toggleable
  in Settings.
- **Rewrite card** — select text anywhere and press <kbd>⌘</kbd><kbd>`</kbd>
  (or hover the pill) for Rephrase / Shorten / Translate tabs, quick-edit chips,
  and a composer for custom instructions.
- **Local models** — pick from a curated catalog (Qwen3 4B recommended, plus
  Gemma 4 E2B, EuroLLM 9B, GRMR V3) downloaded straight from Hugging Face, or
  supply your own `.gguf` — assignable per task (grammar / writing /
  translation). Served by a bundled `llama-server`.
- **First-run onboarding** — guided setup (Accessibility → model) plus a
  hands-on sandbox to try both interactions before using them for real.

## Requirements

- macOS 13+, Apple Silicon (the bundled `llama-server` is arm64)
- ~3 GB disk for a model (downloaded on first run, not bundled)
- Accessibility permission (prompted on first launch)

## Install

From a terminal:

```sh
curl -sL -o /tmp/Nib.zip https://github.com/taranek/nib/releases/latest/download/Nib.zip
ditto -xk /tmp/Nib.zip /tmp/nib-extract && ditto /tmp/nib-extract/Nib.app /Applications/Nib.app
open /Applications/Nib.app
```

The build isn't notarized yet, and a browser download would leave the app
quarantined — Gatekeeper then blocks it (or, at worst, silently hangs the
launch). Installing via `curl` sets no quarantine, so the app just opens.
Updates from then on are in-app: **Settings → Check → Update**.

If you prefer `Nib.dmg` from [Releases](https://github.com/taranek/nib/releases)
instead: after the *"Apple could not verify 'Nib' is free of malware"* dialog,
click **Done**, then **System Settings → Privacy & Security** → *"Nib" was
blocked* → **Open Anyway** — or clear the flag with
`xattr -dr com.apple.quarantine /Applications/Nib.app`.

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

## Model licenses & attributions

Nib ships **no model weights** — models are downloaded from Hugging Face at the
user's request (catalog) or supplied by the user (`.gguf`). Licenses of the
catalog models:

| Model | License |
|---|---|
| Qwen3 4B Instruct 2507 | Apache-2.0 |
| Gemma 4 E2B IT | [Gemma Terms of Use](https://ai.google.dev/gemma/terms) |
| EuroLLM 9B Instruct | Apache-2.0 |
| GRMR V3 4B | Apache-2.0 (derivative of Gemma 3 — Gemma Terms also apply) |

### Harper

Nib's instant English grammar checking is powered by
[Harper](https://writewithharper.com)
([GitHub](https://github.com/Automattic/harper), Apache-2.0) via the
[harper.js](https://www.npmjs.com/package/harper.js) WASM bindings — a
fast, private, rule-based grammar checker. In our JFLEG benchmark it scored
within ~2 GLEU of 4B-class LLMs at roughly 30× their speed.

### CoEdIT

During model evaluation, this project tested
[grammarly/coedit-large](https://huggingface.co/grammarly/coedit-large) —
"CoEdIT: Text Editing by Task-Specific Instruction Tuning" (Raheja, Kumar,
Koo, Kang; 2023) © Grammarly, licensed
[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/).
CoEdIT is **not** bundled with, distributed by, or used in Nib; its
license is **non-commercial**, so it is also not offered in the model
catalog. If you supply a CoEdIT `.gguf` yourself as a custom model, you are
responsible for complying with its non-commercial terms.

## Architecture

| Piece | Where |
|---|---|
| Controller: focus watching, detection, cards, settings | `Sources/loco/Controller/AppController.swift` |
| Harper rule engine host (offscreen WASM webview) | `Sources/loco/LLM/LinterHost.swift` + `web/src/linter.ts` |
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
