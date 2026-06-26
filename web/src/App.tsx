import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import { type CardData, onSetCard, send } from "./bridge";
import { type RewriteState, useRewrite } from "./useRewrite";
import {
  Tabs,
  TabsContent,
  TabsContents,
  TabsList,
  TabsTrigger,
} from "@/components/ui/motion-tabs";
import { Kbd, KbdGroup } from "@/components/ui/kbd";
import { Button } from "@/components/ui/button";
import { motion } from "motion/react";

// Sample so the card is useful when opened in a plain browser too.
const SAMPLE: CardData = {
  mode: "rewrite",
  original: "I think we should make it better.",
  result: "",
  styles: [
    { id: "grammar", label: "Grammar" },
    { id: "rephrase", label: "Rephrase" },
    { id: "shorten", label: "Shorten" },
    { id: "translate", label: "Translate" },
  ],
  llmUrl: "http://127.0.0.1:18080/v1/chat/completions",
  ready: true,
};

export function App() {
  const [card, setCard] = useState<CardData>(SAMPLE);
  const wrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    onSetCard(setCard);
    send({ type: "ready" });
  }, []);

  // Report the card size so the native panel fits it exactly (content height
  // changes as proposals load, so observe the element, not just `card`).
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
    <div className="wrap" ref={wrapRef}>
      {/* Origin-aware entrance: the card's top-left is pinned to the anchor, so
          scaling from there makes it grow out of the trigger. Keyed on the card
          identity so it replays per new card, not on tab switches. */}
      <motion.div
        key={`${card.mode}|${card.original}`}
        className="card"
        style={{ transformOrigin: "top left" }}
        initial={{ opacity: 0, scale: 0.96 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ type: "spring", duration: 0.22, bounce: 0.2 }}
      >
        {card.mode === "grammar" ? (
          <GrammarBody card={card} />
        ) : (
          <RewriteBody key={card.original} card={card} />
        )}
      </motion.div>
    </div>
  );
}

function GrammarBody({ card }: { card: CardData }) {
  const canAccept = card.result.trim() !== card.original.trim() && !!card.result;

  // Keyboard: Enter accepts the correction, Esc dismisses.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        send({ type: "dismiss" });
      } else if (e.key === "Enter" && canAccept) {
        e.preventDefault();
        send({ type: "applyRewrite", text: card.result });
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [canAccept, card.result]);

  return (
    <>
      <div className="rw-content">
        <DiffText original={card.original} result={card.result} />
      </div>
      <Actions canAccept={canAccept} acceptText={card.result} />
    </>
  );
}

function RewriteBody({ card }: { card: CardData }) {
  const [active, setActive] = useState(card.styles[0]?.id ?? "grammar");
  const [results, setResults] = useState<Record<string, RewriteState>>({});
  const onResult = useCallback(
    (id: string, s: RewriteState) => setResults((p) => ({ ...p, [id]: s })),
    [],
  );

  // Keyboard: ←/→ and Tab/⇧Tab cycle the style tabs.
  useEffect(() => {
    const ids = card.styles.map((s) => s.id);
    if (ids.length < 2) return;
    const onKey = (e: KeyboardEvent) => {
      const back = e.key === "ArrowLeft" || (e.key === "Tab" && e.shiftKey);
      const fwd = e.key === "ArrowRight" || (e.key === "Tab" && !e.shiftKey);
      if (!back && !fwd) return;
      e.preventDefault();
      setActive((cur) => {
        const i = Math.max(0, ids.indexOf(cur));
        return ids[(i + (fwd ? 1 : -1) + ids.length) % ids.length];
      });
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [card.styles]);

  const activeRes = results[active];
  const canAccept =
    !!activeRes &&
    !activeRes.loading &&
    !activeRes.error &&
    activeRes.text !== "" &&
    activeRes.text.trim() !== card.original.trim();

  // Keyboard: Enter accepts the active proposal, Esc dismisses.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        send({ type: "dismiss" });
      } else if (e.key === "Enter" && canAccept && activeRes) {
        e.preventDefault();
        send({ type: "applyRewrite", text: activeRes.text });
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [canAccept, activeRes]);

  if (!card.ready) {
    return (
      <>
        <div className="rw-content">
          <div className="rewrite rewrite--loading">Model still loading…</div>
        </div>
        <Actions canAccept={false} acceptText="" />
      </>
    );
  }

  return (
    <>
      <Tabs value={active} onValueChange={setActive} className="gap-0">
        <div className="rw-head">
          <TabsList
            className="h-7 bg-transparent p-0"
            activeClassName="bg-accent shadow-none ring-1 ring-border"
          >
            {card.styles.map((s) => (
              <TabsTrigger
                key={s.id}
                value={s.id}
                className="px-2.5 text-xs text-muted-foreground transition-colors hover:text-foreground"
              >
                {s.label}
              </TabsTrigger>
            ))}
          </TabsList>
        </div>
        <div className="rw-content">
          <TabsContents>
            {card.styles.map((s) => (
              <TabsContent key={s.id} value={s.id}>
                <RewritePanel
                  style={s.id}
                  original={card.original}
                  llmUrl={card.llmUrl}
                  onResult={onResult}
                />
              </TabsContent>
            ))}
          </TabsContents>
        </div>
      </Tabs>
      <Actions canAccept={canAccept} acceptText={activeRes?.text ?? ""} nav />
    </>
  );
}

function RewritePanel({
  style,
  original,
  llmUrl,
  onResult,
}: {
  style: string;
  original: string;
  llmUrl: string;
  onResult: (id: string, s: RewriteState) => void;
}) {
  const st = useRewrite(style, original, llmUrl, true);
  useEffect(() => {
    onResult(style, st);
  }, [style, st.loading, st.text, st.error, onResult]);

  if (st.loading)
    return (
      <div className="rewrite__body">
        <div className="rewrite rewrite--loading">Working…</div>
      </div>
    );
  if (st.error)
    return (
      <div className="rewrite__body">
        <div className="rewrite rewrite--loading">Couldn't reach the model.</div>
      </div>
    );
  // Translation replaces the whole text, so a word-diff would mark everything
  // changed — show the plain translated result instead. If the model returned the
  // text unchanged, it's already English, so don't propose anything.
  if (style === "translate")
    return (
      <div className="rewrite__body">
        {st.text.trim() === original.trim() ? (
          <div className="rewrite rewrite--ok">
            ✓ Already in English — nothing to translate.
          </div>
        ) : (
          <div className="rewrite">{st.text}</div>
        )}
      </div>
    );
  if (st.text.trim() === original.trim())
    return (
      <div className="rewrite__body">
        <div className="rewrite rewrite--ok">✓ Looks good — no changes needed.</div>
      </div>
    );
  return (
    <div className="rewrite__body">
      <DiffText original={original} result={st.text} />
    </div>
  );
}

function Actions({
  canAccept,
  acceptText,
  nav = false,
}: {
  canAccept: boolean;
  acceptText: string;
  nav?: boolean;
}) {
  return (
    <div className="rewrite__row">
      {nav && (
        <span className="nav-hint">
          <KbdGroup>
            <Kbd variant="outline">←</Kbd>
            <Kbd variant="outline">→</Kbd>
          </KbdGroup>
          <span className="nav-hint__label">switch modes</span>
        </span>
      )}
      <Button onClick={() => send({ type: "dismiss" })}>
        {canAccept ? "Dismiss" : "Close"}
        <Kbd variant="outline" className="-me-1 ms-0.5 text-[10px]">ESC</Kbd>
      </Button>
      {canAccept && (
        <Button
          variant="brand"
          onClick={() => send({ type: "applyRewrite", text: acceptText })}
        >
          Accept
          <Kbd variant="outline" className="-me-1 ms-0.5 border-white/20 text-[var(--primary-foreground)] group-hover:text-white">⏎</Kbd>
        </Button>
      )}
    </div>
  );
}

type DiffTok = { text: string; type: "equal" | "del" | "ins" };

/** Word-level LCS diff: removed words struck-through, added words highlighted. */
function diffWords(aStr: string, bStr: string): DiffTok[] {
  const a = aStr.trim().split(/\s+/).filter(Boolean);
  const b = bStr.trim().split(/\s+/).filter(Boolean);
  const n = a.length;
  const m = b.length;
  const dp: number[][] = Array.from({ length: n + 1 }, () =>
    new Array(m + 1).fill(0),
  );
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] =
        a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const out: DiffTok[] = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      out.push({ text: a[i], type: "equal" });
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.push({ text: a[i], type: "del" });
      i++;
    } else {
      out.push({ text: b[j], type: "ins" });
      j++;
    }
  }
  while (i < n) out.push({ text: a[i++], type: "del" });
  while (j < m) out.push({ text: b[j++], type: "ins" });
  return out;
}

function DiffText({ original, result }: { original: string; result: string }) {
  const toks = diffWords(original, result);
  return (
    <div className="rewrite">
      {toks.map((t, i) => (
        <span key={i}>
          <span className={`d d--${t.type}`}>{t.text}</span>{" "}
        </span>
      ))}
    </div>
  );
}
