// The contract between the React UI and the Swift host (WKWebView).
//
//  Swift → JS : window.loco.setCard(data) / window.loco.setSettings(state)
//  JS → Swift : window.webkit.messageHandlers.loco.postMessage({...})
//
// The same bundle drives two surfaces, picked by URL hash: the card (default)
// and the settings window (#settings).

export interface RewriteStyleOption {
  id: string;
  label: string;
}

/** Card data pushed from Swift. Grammar carries a precomputed `result`; rewrite
 *  carries `styles` + `llmUrl` and React fetches each style from the LLM. */
export interface CardData {
  mode: "grammar" | "rewrite";
  /** The text the accepted result will replace. */
  original: string;
  /** Grammar only: the corrected sentence. */
  result: string;
  /** Rewrite only: the style tabs. */
  styles: RewriteStyleOption[];
  /** Rewrite only: the local LLM chat-completions URL React fetches. */
  llmUrl: string;
  /** Whether the local model is ready. */
  ready: boolean;
  /** Target language for the Translate tab (default "English"). */
  targetLanguage: string;
}

export interface SettingsState {
  enabled: boolean;
  accessibilityTrusted: boolean;
  /** Local LLM status, e.g. "Loading model…", "Ready", "Error: …". */
  llmStatus: string;
  /** The loaded GGUF model's filename. */
  model: string;
  /** Default target language for translations. */
  targetLanguage: string;
}

type OutboundMessage =
  | { type: "ready" }
  | { type: "applyRewrite"; text: string }
  | { type: "dismiss" }
  | { type: "resize"; width: number; height: number }
  | { type: "setEnabled"; value: boolean }
  | { type: "setTargetLanguage"; value: string }
  | { type: "openAccessibility" }
  | { type: "chooseModel" }
  | { type: "quit" };

interface WebkitBridge {
  messageHandlers?: {
    loco?: { postMessage: (msg: OutboundMessage) => void };
  };
}

interface LocoInbound {
  setCard?: (data: CardData) => void;
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

/** Register the inbound entry point Swift calls to push card data. */
export function onSetCard(handler: (data: CardData) => void): void {
  window.loco = { ...window.loco, setCard: handler };
}

/** Register the inbound entry point Swift calls to push settings state. */
export function onSetSettings(handler: (state: SettingsState) => void): void {
  window.loco = { ...window.loco, setSettings: handler };
}
