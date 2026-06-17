import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { type Suggestion, onSetSuggestion, send } from "./bridge";

// Sample so the card is useful when opened in a plain browser too.
const SAMPLE: Suggestion = {
  category: "Correctness",
  suggestion: "the",
  message: "“teh” → “the”",
  word: "teh",
};

const inWebView = Boolean(window.webkit?.messageHandlers?.loco);

export function App() {
  const [s, setS] = useState<Suggestion>(SAMPLE);
  const wrapRef = useRef<HTMLDivElement>(null);

  // Receive the suggestion pushed from Swift, and announce readiness.
  useEffect(() => {
    onSetSuggestion(setS);
    send({ type: "ready" });
  }, []);

  // Report the card size so the native panel fits it exactly (no clipped
  // shadow, no scrollbar).
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
  }, [s]);

  return (
    <div className="wrap" ref={wrapRef}>
      <div className="card">
        <div className="card__cat">{s.category}</div>

        <button className="sugg" onClick={() => send({ type: "apply" })}>
          {s.suggestion}
        </button>

        <button className="action" onClick={() => send({ type: "dismiss" })}>
          <TrashIcon />
          <span>Dismiss</span>
        </button>

        <div className="foot">
          <span className="foot__mark">loco</span>
          <span>Powered by loco</span>
        </div>
      </div>
    </div>
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
