import { useEffect, useState } from "react";
import { ChevronDown } from "lucide-react";
import { type SettingsState, onSetSettings, send } from "./bridge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

const LANGUAGES = [
  "English",
  "Spanish",
  "German",
  "French",
  "Italian",
  "Portuguese",
  "Dutch",
  "Polish",
  "Japanese",
  "Chinese",
];

const inWebView = Boolean(window.webkit?.messageHandlers?.loco);

export function Settings() {
  const [state, setState] = useState<SettingsState>({
    enabled: true,
    accessibilityTrusted: inWebView ? false : true,
    llmStatus: inWebView ? "Loading model…" : "Ready",
    model: "gemma-4-E2B-it-Q4_K_M.gguf",
    targetLanguage: "English",
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
        <div className="settings__row">
          <div className="settings__field">
            <span className="settings__row-label">Suggestions</span>
            <span className="settings__hint">
              Grammar &amp; rewrite help as you type.
            </span>
          </div>
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
          </label>
        </div>
      </section>

      <section className="settings__section">
        <div className="settings__row">
          <div className="settings__field">
            <span className="settings__row-label">Translate to</span>
            <span className="settings__hint">
              Translate suggestions render in this language.
            </span>
          </div>
          <DropdownMenu modal={false}>
            <DropdownMenuTrigger asChild>
              <button className="select-trigger">
                {state.targetLanguage}
                <ChevronDown className="size-3.5 opacity-60" />
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent
              align="end"
              className="max-h-(--radix-dropdown-menu-content-available-height) min-w-40 overflow-y-auto"
            >
              <DropdownMenuRadioGroup
                value={state.targetLanguage}
                onValueChange={(value) => {
                  setState((s) => ({ ...s, targetLanguage: value }));
                  send({ type: "setTargetLanguage", value });
                }}
              >
                {LANGUAGES.map((lang) => (
                  <DropdownMenuRadioItem key={lang} value={lang}>
                    {lang}
                  </DropdownMenuRadioItem>
                ))}
              </DropdownMenuRadioGroup>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </section>

      <section className="settings__section">
        <div className="settings__row">
          <div className="settings__field">
            <span className="settings__row-label">
              <span className={"status__dot " + (llmReady ? "is-ok" : "is-warn")} />
              Local AI
            </span>
            <span className="pill" title={state.model}>
              {llmReady ? state.model : state.llmStatus}
            </span>
          </div>
          <Button
            size="sm"
            variant="default"
            onClick={() => send({ type: "chooseModel" })}
          >
            Change
          </Button>
        </div>
      </section>

      <section className="settings__section">
        <div className="settings__row">
          <div className="settings__field">
            <span className="settings__row-label">
              <span
                className={
                  "status__dot " +
                  (state.accessibilityTrusted ? "is-ok" : "is-warn")
                }
              />
              Accessibility
            </span>
            <span className="settings__hint">
              {state.accessibilityTrusted
                ? "Access granted."
                : "Required to read & edit text in other apps."}
            </span>
          </div>
          <Button
            size="sm"
            variant={state.accessibilityTrusted ? "default" : "brand"}
            onClick={() => send({ type: "openAccessibility" })}
          >
            Open
          </Button>
        </div>
      </section>
    </div>
  );
}
