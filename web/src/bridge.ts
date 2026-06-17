// The contract between the React card and the Swift host (WKWebView).
//
//  Swift → JS : window.loco.setSuggestion(s)   (called via evaluateJavaScript)
//  JS → Swift : window.webkit.messageHandlers.loco.postMessage({...})

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

type OutboundMessage =
  | { type: "ready" }
  | { type: "apply" }
  | { type: "dismiss" }
  | { type: "resize"; width: number; height: number };

interface WebkitBridge {
  messageHandlers?: {
    loco?: { postMessage: (msg: OutboundMessage) => void };
  };
}

declare global {
  interface Window {
    webkit?: WebkitBridge;
    loco?: { setSuggestion: (s: Suggestion) => void };
  }
}

/** Send a message to the Swift host (no-op in a plain browser). */
export function send(msg: OutboundMessage): void {
  window.webkit?.messageHandlers?.loco?.postMessage(msg);
}

/** Register the inbound entry point Swift calls to push a suggestion. */
export function onSetSuggestion(handler: (s: Suggestion) => void): void {
  window.loco = { setSuggestion: handler };
}
