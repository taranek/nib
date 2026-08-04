// The Harper linter surface: an offscreen webview (window.__locoLinter) that
// lints English text with harper.js (WASM, rule-based, ~milliseconds) and
// reports precise UTF-16 spans + suggestions back to Swift.
//
//  Swift → JS : window.loco.lint(text, id)
//  JS → Swift : postMessage({type:"lints", id, lints:[{start,end,message,suggestions}]})
//               postMessage({type:"linterReady"})
//
// The inlined binary (data URL) works under both http:// (dev) and file://
// (packaged app); this module is only loaded on the linter surface, so the
// ~15MB WASM never weighs down the card/settings bundles.
import { LocalLinter } from "harper.js";
import { binaryInlined } from "harper.js/binaryInlined";

interface LintOut {
  start: number;
  end: number;
  message: string;
  suggestions: string[];
}

// Window.loco is declared in bridge.ts (LocoInbound, including `lint`).
import type {} from "./bridge";

function post(msg: unknown): void {
  (
    window as unknown as {
      webkit?: {
        messageHandlers?: { loco?: { postMessage: (m: unknown) => void } };
      };
    }
  ).webkit?.messageHandlers?.loco?.postMessage(msg);
}

const linter = new LocalLinter({ binary: binaryInlined });

async function lint(text: string, id: number): Promise<void> {
  try {
    const lints = await linter.lint(text);
    const out: LintOut[] = lints.map((l) => {
      const span = l.span();
      return {
        start: span.start,
        end: span.end,
        message: l.message(),
        suggestions: l.suggestions().map((s) => s.get_replacement_text()),
      };
    });
    post({ type: "lints", id, lints: out });
  } catch {
    post({ type: "lints", id, lints: [] });
  }
}

linter.setup().then(() => {
  window.loco = { ...window.loco, lint: (t: string, id: number) => void lint(t, id) };
  post({ type: "linterReady" });
});
