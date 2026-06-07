# loco

Mac-first proof-of-concept for a Grammarly-style overlay: read the focused text
field of **any** app via the macOS Accessibility API, and draw inline geometry
through a transparent, click-through, always-on-top window.

This PoC deliberately proves only the riskiest part — **cross-app text + per-word
screen geometry + a non-intrusive overlay**. There is no NLP/suggestion engine
yet; red bars stand in for where real squiggles would go.

## Run

```sh
swift run loco
```

First launch triggers an Accessibility permission prompt:

1. **System Settings → Privacy & Security → Accessibility**
2. Enable the entry for the binary (or for your terminal app, e.g. Terminal/iTerm —
   macOS often attributes CLI tools to their parent).
3. Re-run `swift run loco`.

Then click into a text field anywhere (Notes, Safari address bar, TextEdit, a
native `NSTextField`) and type. You should see:

- a **blue box** outlining the focused element, and
- **red bars** under each word, positioned by `AXBoundsForRange`.

## What it demonstrates

| Capability | Where |
|---|---|
| Find the system-wide focused element | `AX.focusedElement()` |
| Read its text value & role | `AX.string(_:_:)` |
| Element frame in screen coords | `AX.frame(_:)` |
| **Per-range pixel geometry** | `AX.bounds(of:in:)` → `AXBoundsForRange` |
| Transparent / click-through / top window | `OverlayWindow` |
| AX (top-left) → AppKit (bottom-left) coord flip | `AppController.toCocoa(_:)` |

## Known PoC limitations (by design)

- **Single screen.** `toCocoa` flips against the primary screen height only;
  multi-monitor needs per-screen mapping.
- **Polling, not events.** Samples focus at ~8 Hz. Production should use an
  `AXObserver` per-app for focus/value/selection notifications.
- **Coverage is uneven.** Native Cocoa controls expose text + bounds well.
  Electron, custom-drawn editors, and many cross-platform apps expose little —
  `AXBoundsForRange` returns nil and only the field box (or nothing) shows. This
  is the real-world ceiling of the AX approach and must be handled with graceful
  degradation (panel-only suggestions).

## Next steps

1. Swap polling for `AXObserver` focus/value/selection notifications.
2. Add multi-monitor coordinate mapping.
3. Make a sub-region of the overlay interactive (drop `ignoresMouseEvents` for a
   suggestion card; keep it for the underlines).
4. Wire a debounced WebSocket client to a server-side NLP/LLM service; map
   returned ranges back through `AX.bounds(of:in:)`.
