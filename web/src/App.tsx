import { useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  type Rewrite,
  type Suggestion,
  onSetRewrite,
  onSetSuggestion,
  send,
} from "./bridge";

// Sample so the card is useful when opened in a plain browser too.
const SAMPLE: Suggestion = {
  category: "Grammar",
  suggestion: "the",
  message: "“teh” → “the”",
  word: "teh",
};

const inWebView = Boolean(window.webkit?.messageHandlers?.loco);

type View =
  | { kind: "grammar"; suggestion: Suggestion }
  | { kind: "rewrite"; rewrite: Rewrite };

export function App() {
  const [view, setView] = useState<View>({ kind: "grammar", suggestion: SAMPLE });
  const wrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    onSetSuggestion((suggestion) => setView({ kind: "grammar", suggestion }));
    onSetRewrite((rewrite) => setView({ kind: "rewrite", rewrite }));
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
  }, [view]);

  return (
    <div className="wrap" ref={wrapRef}>
      <div className="card">
        {view.kind === "grammar"
          ? <GrammarCard s={view.suggestion} />
          : <RewriteCard r={view.rewrite} />}
      </div>
    </div>
  );
}

function GrammarCard({ s }: { s: Suggestion }) {
  return (
    <>
      <div className="card__cat">{s.category}</div>
      <button className="sugg" onClick={() => send({ type: "apply" })}>
        {s.suggestion}
      </button>
      <button className="action" onClick={() => send({ type: "dismiss" })}>
        <TrashIcon />
        <span>Dismiss</span>
      </button>
    </>
  );
}

function RewriteCard({ r }: { r: Rewrite }) {
  return (
    <>
      <div className="card__cat">{r.action}</div>
      {r.loading ? (
        <div className="rewrite rewrite--loading">Rephrasing…</div>
      ) : r.unchanged ? (
        <div className="rewrite rewrite--ok">✓ Looks good — no changes needed.</div>
      ) : (
        <div className="rewrite">{r.result}</div>
      )}
      <div className="rewrite__row">
        {!r.unchanged && (
          <button
            className="btn"
            disabled={r.loading || !r.result}
            onClick={() => send({ type: "applyRewrite" })}
          >
            Accept
          </button>
        )}
        <button className="btn btn--ghost" onClick={() => send({ type: "dismiss" })}>
          {r.unchanged ? "Close" : "Dismiss"}
        </button>
      </div>
    </>
  );
}

function TrashIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden>
      <path
        d="M3 4h10M6.5 4V3a1 1 0 0 1 1-1h1a1 1 0 0 1 1 1v1M5 4l.5 8a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1L11 4"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
