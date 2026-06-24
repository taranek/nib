// The contract between the React UI and the Swift host (WKWebView).
//
//  Swift → JS : window.loco.setSuggestion(s) / window.loco.setSettings(state)
//  JS → Swift : window.webkit.messageHandlers.loco.postMessage({...})
//
// The same bundle drives two surfaces, picked by URL hash: the per-word card
// (default) and the settings window (#settings).

export interface Suggestion {
  /** Category label shown above the suggestion (e.g. "Correctness"). */
  category: string;
  /** The replacement text — the primary click-to-apply action. */
  suggestion: string;
  /** Human-readable description, e.g. “teh” → “the”. */
  message: string;
  /** The original flagged word. */
  word: string;
}

export interface Rewrite {
  /** Action label, e.g. "Rephrase". */
  action: string;
  /** The original selected text. */
  original: string;
  /** The proposed rewrite (empty while loading). */
  result: string;
  /** True until the model returns. */
  loading: boolean;
  /** True when the proposal matches the input (nothing to apply). */
  unchanged: boolean;
}

export interface SettingsState {
  enabled: boolean;
  accessibilityTrusted: boolean;
  /** Local LLM status, e.g. "Loading model…", "Ready", "Error: …". */
  llmStatus: string;
  /** The loaded GGUF model's filename. */
  model: string;
}

type OutboundMessage =
  | { type: "ready" }
  | { type: "apply" }
  | { type: "applyRewrite" }
  | { type: "dismiss" }
  | { type: "resize"; width: number; height: number }
  | { type: "setEnabled"; value: boolean }
  | { type: "openAccessibility" }
  | { type: "quit" };

interface WebkitBridge {
  messageHandlers?: {
    loco?: { postMessage: (msg: OutboundMessage) => void };
  };
}

interface LocoInbound {
  setSuggestion?: (s: Suggestion) => void;
  setRewrite?: (r: Rewrite) => void;
  setSettings?: (state: SettingsState) => void;
}

declare global {
  interface Window {
    webkit?: WebkitBridge;
    loco?: LocoInbound;
  }
}

/** Send a message to the Swift host (no-op in a plain browser). */
export function send(msg: OutboundMessage): void {
  window.webkit?.messageHandlers?.loco?.postMessage(msg);
}

/** Register the inbound entry point Swift calls to push a suggestion. */
export function onSetSuggestion(handler: (s: Suggestion) => void): void {
  window.loco = { ...window.loco, setSuggestion: handler };
}

/** Register the inbound entry point Swift calls to push a rephrase proposal. */
export function onSetRewrite(handler: (r: Rewrite) => void): void {
  window.loco = { ...window.loco, setRewrite: handler };
}

/** Register the inbound entry point Swift calls to push settings state. */
export function onSetSettings(handler: (state: SettingsState) => void): void {
  window.loco = { ...window.loco, setSettings: handler };
}
