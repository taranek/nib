import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { type SettingsState, onSetSettings, send } from "./bridge";
import { Button } from "@/components/ui/button";
import { Select } from "@/components/ui/select";
import { Toggle } from "@/components/ui/toggle";
import { Pill } from "@/components/ui/pill";
import { StatusDot } from "@/components/ui/status-dot";

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

const SECTION = "flex flex-col gap-2.5 border-t border-border pt-3.5";
const ROW = "flex items-center justify-between gap-3";
const FIELD = "flex min-w-0 flex-col gap-0.5";
const LABEL = "inline-flex items-center gap-[7px] text-[14px] text-foreground";
const HINT = "text-[12px] text-muted-foreground [overflow-wrap:anywhere]";
const CARD_SHADOW =
  "shadow-[0_6px_16px_rgba(0,0,0,0.4),0_1px_4px_rgba(0,0,0,0.3),inset_0_1px_0_rgba(255,255,255,0.05)]";

export function Settings() {
  const [state, setState] = useState<SettingsState>({
    enabled: true,
    accessibilityTrusted: inWebView ? false : true,
    llmStatus: inWebView ? "Loading model…" : "Ready",
    model: "gemma-4-E2B-it-Q4_K_M.gguf",
    targetLanguage: "English",
  });

  const llmReady = state.llmStatus.toLowerCase() === "ready";
  const wrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    onSetSettings(setState);
    send({ type: "ready" });
  }, []);

  // Report the card size so the native panel fits it exactly.
  useLayoutEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const report = () =>
      send({
        type: "resize",
        width: Math.ceil(el.offsetWidth),
        height: Math.ceil(el.offsetHeight),
      });
    report();
    const ro = new ResizeObserver(report);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  return (
    <div className="w-max p-6" ref={wrapRef}>
      <div
        className={`box-border flex w-[380px] flex-col gap-3.5 overflow-hidden rounded-[12px] border border-border bg-card p-4 text-[13px] text-[var(--text-secondary)] ${CARD_SHADOW}`}
      >
        <header className="flex flex-col gap-0.5">
          <span className="text-[18px] font-bold tracking-[-0.02em] text-foreground">
            loco
          </span>
          <span className="text-[12px] text-muted-foreground">
            Writing suggestions, over any app.
          </span>
        </header>

        <section className={SECTION}>
          <div className={ROW}>
            <div className={FIELD}>
              <span className={LABEL}>Suggestions</span>
              <span className={HINT}>Grammar &amp; rewrite help as you type.</span>
            </div>
            <Toggle
              checked={state.enabled}
              onCheckedChange={(value) => {
                setState((s) => ({ ...s, enabled: value }));
                send({ type: "setEnabled", value });
              }}
            />
          </div>
        </section>

        <section className={SECTION}>
          <div className={ROW}>
            <div className={FIELD}>
              <span className={LABEL}>Translate to</span>
              <span className={HINT}>
                Translate suggestions render in this language.
              </span>
            </div>
            <Select
              value={state.targetLanguage}
              options={LANGUAGES}
              onValueChange={(value) => {
                setState((s) => ({ ...s, targetLanguage: value }));
                send({ type: "setTargetLanguage", value });
              }}
            />
          </div>
        </section>

        <section className={SECTION}>
          <div className={ROW}>
            <div className={FIELD}>
              <span className={LABEL}>
                <StatusDot ok={llmReady} />
                Local AI
              </span>
              <Pill title={state.model}>
                {llmReady ? state.model : state.llmStatus}
              </Pill>
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

        <section className={SECTION}>
          <div className={ROW}>
            <div className={FIELD}>
              <span className={LABEL}>
                <StatusDot ok={state.accessibilityTrusted} />
                Accessibility
              </span>
              <span className={HINT}>
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
    </div>
  );
}
