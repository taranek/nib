import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { type Issue, onSetIssues, send } from "./bridge";

// Sample data so the page is useful when opened in a plain browser too.
const SAMPLE: Issue[] = [
  { message: "“teh” → “the”", replacement: "the" },
  { message: "“wierd” → “weird”", replacement: "weird" },
  { message: "“definately” → “definitely”", replacement: "definitely" },
  { message: "“alot” → “a lot”", replacement: "a lot" },
];

const inWebView = Boolean(window.webkit?.messageHandlers?.loco);

export function App() {
  const [issues, setIssues] = useState<Issue[]>(inWebView ? [] : SAMPLE);
  const wrapRef = useRef<HTMLDivElement>(null);

  // Receive issues pushed from Swift, and announce readiness.
  useEffect(() => {
    onSetIssues(setIssues);
    send({ type: "ready" });
  }, []);

  // Report the OUTER wrapper size (card + shadow padding) so the native panel
  // contains everything — no clipped shadow, no scrollbar.
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
  }, [issues]);

  return (
    <div className="wrap" ref={wrapRef}>
      <div className="card">
        <header className="card__head">
          <span className="card__logo">loco</span>
          <span className="card__count">
            {issues.length} suggestion{issues.length === 1 ? "" : "s"}
          </span>
          {issues.length > 1 && (
            <button className="btn btn--ghost" onClick={() => send({ type: "fixAll" })}>
              Fix all
            </button>
          )}
        </header>

        <ul className="list">
          {issues.map((issue, index) => (
            <li className="row" key={index}>
              <span className="row__msg">{issue.message}</span>
              <button className="btn" onClick={() => send({ type: "fix", index })}>
                Fix
              </button>
            </li>
          ))}
          {issues.length === 0 && <li className="row row--empty">No suggestions</li>}
        </ul>
      </div>
    </div>
  );
}
