// The contract between the React UI and the Swift host (WKWebView).
//
//  Swift → JS : window.loco.setIssues(issues)   (called via evaluateJavaScript)
//  JS → Swift : window.webkit.messageHandlers.loco.postMessage({...})

export interface Issue {
  message: string;
  replacement: string;
}

type OutboundMessage =
  | { type: "ready" }
  | { type: "fix"; index: number }
  | { type: "fixAll" }
  | { type: "resize"; width: number; height: number };

interface WebkitBridge {
  messageHandlers?: {
    loco?: { postMessage: (msg: OutboundMessage) => void };
  };
}

declare global {
  interface Window {
    webkit?: WebkitBridge;
    loco?: { setIssues: (issues: Issue[]) => void };
  }
}

/** Send a message to the Swift host (no-op in a plain browser). */
export function send(msg: OutboundMessage): void {
  window.webkit?.messageHandlers?.loco?.postMessage(msg);
}

/** Register the inbound entry point Swift calls to push issues. */
export function onSetIssues(handler: (issues: Issue[]) => void): void {
  window.loco = { setIssues: handler };
}
