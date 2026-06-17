import { useEffect, useState } from "react";
import { type SettingsState, onSetSettings, send } from "./bridge";

const inWebView = Boolean(window.webkit?.messageHandlers?.loco);

export function Settings() {
  const [state, setState] = useState<SettingsState>({
    enabled: true,
    accessibilityTrusted: inWebView ? false : true,
    llmStatus: inWebView ? "Loading model…" : "Ready",
    model: "gemma-4-E2B-it-Q4_K_M.gguf",
  });

  const llmReady = state.llmStatus.toLowerCase() === "ready";

  useEffect(() => {
    onSetSettings(setState);
    send({ type: "ready" });
  }, []);

  return (
    <div className="settings">
      <header className="settings__head">
        <span className="settings__logo">loco</span>
        <span className="settings__sub">Writing suggestions, over any app.</span>
      </header>

      <section className="settings__section">
        <label className="toggle">
          <input
            type="checkbox"
            checked={state.enabled}
            onChange={(e) => {
              const value = e.target.checked;
              setState((s) => ({ ...s, enabled: value }));
              send({ type: "setEnabled", value });
            }}
          />
          <span className="toggle__track" />
          <span className="toggle__label">Enable suggestions</span>
        </label>
      </section>

      <section className="settings__section">
        <div className="status">
          <span className={"status__dot " + (llmReady ? "is-ok" : "is-warn")} />
          <span>Local AI: {state.llmStatus}</span>
        </div>
        <div className="settings__meta">{state.model}</div>
      </section>

      <section className="settings__section">
        <div className="status">
          <span
            className={
              "status__dot " + (state.accessibilityTrusted ? "is-ok" : "is-warn")
            }
          />
          <span>
            {state.accessibilityTrusted
              ? "Accessibility access granted"
              : "Accessibility access required"}
          </span>
        </div>
        <button
          className={"btn" + (state.accessibilityTrusted ? " btn--ghost" : "")}
          onClick={() => send({ type: "openAccessibility" })}
        >
          Open Accessibility Settings…
        </button>
      </section>

      <footer className="settings__foot">
        <button
          className="btn btn--ghost"
          onClick={() => send({ type: "quit" })}
        >
          Quit loco
        </button>
      </footer>
    </div>
  );
}
