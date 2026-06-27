import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import { type CardData, onSetCard, send } from "./bridge";
import {
  type ChatMsg,
  type RewriteState,
  chatRefine,
  refineSystem,
  useLanguage,
  useRewrite,
} from "./useRewrite";
import {
  Tabs,
  TabsContent,
  TabsContents,
  TabsList,
  TabsTrigger,
} from "@/components/ui/motion-tabs";
import { Kbd, KbdGroup } from "@/components/ui/kbd";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { motion } from "motion/react";
import { ArrowUp, Check, Loader2, RefreshCw } from "lucide-react";

// Quick-filter edits shown as chips above the composer (Rephrase tab).
const CHIPS: { label: string; instruction: string }[] = [
  { label: "Shorten", instruction: "Make it more concise." },
  { label: "Expand", instruction: "Expand it with a bit more detail." },
  { label: "More formal", instruction: "Make it more formal." },
  { label: "Confident", instruction: "Make it sound more confident and assertive." },
];

// Sample so the card is useful when opened in a plain browser too.
const SAMPLE: CardData = {
  mode: "rewrite",
  original: "I think we should make it better.",
  result: "",
  styles: [
    { id: "grammar", label: "Grammar" },
    { id: "rephrase", label: "Rephrase" },
    { id: "translate", label: "Translate" },
  ],
  llmUrl: "http://127.0.0.1:18080/v1/chat/completions",
  ready: true,
  targetLanguage: "English",
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
    // The .wrap padding is the card's transparent shadow margin; clicking it (the
    // shadow area around the card) counts as clicking outside → dismiss.
    <div
      className="wrap"
      ref={wrapRef}
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) send({ type: "dismiss" });
      }}
    >
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

  // Keyboard: Tab accepts the correction, Esc dismisses.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        send({ type: "dismiss" });
      } else if (e.key === "Tab" && canAccept) {
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
  // Per-style retry counter: bumping it re-runs that style with variation.
  const [attempts, setAttempts] = useState<Record<string, number>>({});
  // Per-style refinement: the latest feedback-revised text, and which is loading.
  const [refined, setRefined] = useState<Record<string, string>>({});
  // Per-style refine conversation (user instructions + assistant results) so
  // custom prompts accumulate; "Try again" replays the last turn for a variation.
  const [chats, setChats] = useState<Record<string, ChatMsg[]>>({});
  const [refiningStyle, setRefiningStyle] = useState<string | null>(null);
  const [feedback, setFeedback] = useState("");
  // The quick-filter chip whose edit is currently applied (for the active state).
  const [activeChip, setActiveChip] = useState<string | null>(null);
  const onResult = useCallback(
    (id: string, s: RewriteState) => setResults((p) => ({ ...p, [id]: s })),
    [],
  );

  // All styles are always available (Translate included); the active tab is the
  // user's pick. Tabs lazy-fetch, so Translate only runs when opened.
  const visibleStyles = card.styles;
  const visibleIds = visibleStyles.map((s) => s.id).join("|");
  const current = active;

  // Detect the text's language (tiny cached LLM call) so Grammar/Rephrase/Shorten
  // reply in it (e.g. Polish in → Polish out). Rephrase/Shorten wait for it (they
  // translate to English without an explicit language); Grammar/Translate don't.
  const { loading: langLoading, lang: language } = useLanguage(
    card.original,
    card.llmUrl,
    card.ready,
  );
  const needsLang = (id: string) => id === "rephrase";

  // Move between tabs by `dir` (wraps).
  const cycle = useCallback(
    (dir: 1 | -1) => {
      const ids = visibleIds.split("|");
      if (ids.length < 2) return;
      setActive((cur) => {
        const i = Math.max(0, ids.indexOf(cur));
        return ids[(i + dir + ids.length) % ids.length];
      });
    },
    [visibleIds],
  );

  // Keyboard: ←/→ cycle the style tabs (Tab confirms). Skipped while an input is
  // focused — the composer handles its own arrows so it can cycle tabs too.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target;
      if (t instanceof HTMLInputElement || t instanceof HTMLTextAreaElement)
        return;
      if (e.key === "ArrowLeft") {
        e.preventDefault();
        cycle(-1);
      } else if (e.key === "ArrowRight") {
        e.preventDefault();
        cycle(1);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [cycle]);

  const activeRes = results[current];
  const refining = refiningStyle === current;
  // What's currently shown/acceptable: the refinement if any, else the result.
  const activeText = refined[current] ?? activeRes?.text ?? "";
  const canAccept =
    !refining &&
    (refined[current] != null ||
      (!!activeRes && !activeRes.loading && !activeRes.error)) &&
    activeText !== "" &&
    activeText.trim() !== card.original.trim();

  // Refine the currently-shown text with an instruction (from the composer or a
  // quick-filter chip).
  // Send a refine conversation and store the new turn + result.
  const sendRefine = useCallback(
    (style: string, convo: ChatMsg[]) => {
      setRefiningStyle(style);
      const full: ChatMsg[] = [
        { role: "system", content: refineSystem(language) },
        ...convo,
      ];
      chatRefine(full, card.llmUrl).then((out) => {
        setRefiningStyle((s) => (s === style ? null : s));
        if (!out) return;
        setChats((p) => ({
          ...p,
          [style]: [...convo, { role: "assistant", content: out }],
        }));
        setRefined((p) => ({ ...p, [style]: out }));
      });
    },
    [card.llmUrl, language],
  );

  // Apply an instruction. `reset` (chips) starts a fresh conversation from the
  // original; otherwise it continues the existing one (custom prompts accumulate).
  const runInstruction = useCallback(
    (instruction: string, base: string | undefined, reset: boolean) => {
      if (!instruction.trim() || refiningStyle) return;
      const style = current;
      const prior = reset ? [] : (chats[style] ?? []);
      const userMsg: ChatMsg =
        prior.length === 0
          ? {
              role: "user",
              content: `Here is the text:\n${base ?? ""}\n\nInstruction: ${instruction}`,
            }
          : { role: "user", content: instruction };
      if (prior.length === 0 && !base) return;
      sendRefine(style, [...prior, userMsg]);
    },
    [refiningStyle, current, chats, sendRefine],
  );

  // "Try again": if a conversation exists, replay its last user turn for a fresh
  // variation; otherwise regenerate the base tab with variation.
  const retry = useCallback(() => {
    const convo = chats[current];
    if (convo?.length) {
      const last = convo[convo.length - 1];
      const upToUser = last.role === "assistant" ? convo.slice(0, -1) : convo;
      sendRefine(current, upToUser);
      return;
    }
    setActiveChip(null);
    setAttempts((p) => ({ ...p, [current]: (p[current] ?? 0) + 1 }));
  }, [current, chats, sendRefine]);

  // Composer feedback continues the conversation (accumulates on prior results).
  const submitFeedback = useCallback(() => {
    const instruction = feedback.trim();
    if (!instruction) return;
    setFeedback("");
    setActiveChip(null); // custom feedback → no chip is "active"
    runInstruction(instruction, refined[current] ?? activeRes?.text, false);
  }, [feedback, runInstruction, refined, activeRes, current]);

  // Keyboard: Tab accepts the active proposal, Esc dismisses. Ignored while the
  // feedback input is focused (it has its own keys).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target;
      if (t instanceof HTMLInputElement || t instanceof HTMLTextAreaElement)
        return;
      if (e.key === "Escape") {
        e.preventDefault();
        send({ type: "dismiss" });
      } else if (e.key === "Tab" && canAccept) {
        e.preventDefault();
        send({ type: "applyRewrite", text: activeText });
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [canAccept, activeText]);

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
      <Tabs value={current} onValueChange={setActive} className="gap-0">
        <div className="rw-head">
          <TabsList
            className="h-7 bg-transparent p-0"
            activeClassName="bg-accent shadow-none ring-1 ring-border"
          >
            {visibleStyles.map((s) => {
              const r = results[s.id];
              const ready = !!r && !r.loading && !r.error;
              const unchanged = ready && r.text.trim() === card.original.trim();
              // Grammar "all good" only once we've confirmed the text is English
              // (the English-only model leaves foreign text unchanged, which would
              // otherwise read as a false "no errors").
              const ok = s.id === "grammar" && unchanged;
              // Grammar with changes → badge with the number of fixes (9+ max).
              const errors =
                s.id === "grammar" && ready && !unchanged
                  ? countChanges(card.original, r.text)
                  : 0;
              return (
                <TabsTrigger
                  key={s.id}
                  value={s.id}
                  className="gap-1 px-2.5 text-xs text-muted-foreground transition-colors hover:text-foreground"
                >
                  {s.label}
                  {ok && (
                    <Check
                      className="size-3 text-[var(--diff-ins)]"
                      strokeWidth={3}
                    />
                  )}
                  {errors > 0 && (
                    <span className="tab-badge">
                      {errors > 9 ? "9+" : errors}
                    </span>
                  )}
                </TabsTrigger>
              );
            })}
          </TabsList>
          {current !== "grammar" && (
            <button
              className="rw-feedback__send rw-feedback__send--tall"
              aria-label="Try again"
              onClick={retry}
            >
              <RefreshCw className="size-3.5" />
            </button>
          )}
        </div>
        <div className="rw-content">
          <TabsContents>
            {visibleStyles.map((s) => (
              <TabsContent key={s.id} value={s.id}>
                <RewritePanel
                  style={s.id}
                  original={card.original}
                  llmUrl={card.llmUrl}
                  enabled={
                    s.id === current && (!needsLang(s.id) || !langLoading)
                  }
                  language={language}
                  attempt={attempts[s.id] ?? 0}
                  target={card.targetLanguage}
                  override={refined[s.id]}
                  refining={refiningStyle === s.id}
                  onResult={onResult}
                />
              </TabsContent>
            ))}
          </TabsContents>
        </div>
      </Tabs>
      {current === "rephrase" && (
        <div className="rw-chips">
          {CHIPS.map((c) => (
            <button
              key={c.label}
              className={`chip${activeChip === c.label ? " chip--active" : ""}`}
              disabled={refining}
              onClick={() => {
                setActiveChip(c.label);
                // chips start a fresh conversation from the original
                runInstruction(c.instruction, card.original, true);
              }}
            >
              {c.label}
            </button>
          ))}
        </div>
      )}
      <div className="rw-footer">
        {current === "rephrase" && (
          <>
            <input
              className="rw-feedback__input"
              placeholder="Tell the model what to change…"
              value={feedback}
              disabled={refining}
              autoFocus
              onChange={(e) => setFeedback(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  submitFeedback();
                } else if (e.key === "ArrowLeft") {
                  // Keep tab-cycling working even though the composer is focused.
                  e.preventDefault();
                  cycle(-1);
                } else if (e.key === "ArrowRight") {
                  e.preventDefault();
                  cycle(1);
                }
              }}
            />
            <button
              className="rw-feedback__send rw-feedback__send--tall"
              aria-label="Send feedback"
              disabled={refining || !feedback.trim()}
              onClick={submitFeedback}
            >
              {refining ? (
                <Loader2 className="size-3.5 animate-spin" />
              ) : (
                <ArrowUp className="size-3.5" />
              )}
            </button>
          </>
        )}
        <Button
          variant="brand"
          disabled={!canAccept}
          onClick={() => send({ type: "applyRewrite", text: activeText })}
        >
          Accept
          <Kbd variant="outline" className="-me-1 ms-0.5 border-white/20 text-[10px] text-[var(--primary-foreground)] group-hover:text-white">TAB</Kbd>
        </Button>
      </div>
    </>
  );
}

function RewritePanel({
  style,
  original,
  llmUrl,
  enabled,
  language,
  attempt,
  target,
  override,
  refining,
  onResult,
}: {
  style: string;
  original: string;
  llmUrl: string;
  enabled: boolean;
  language: string | null;
  attempt: number;
  target: string;
  override?: string;
  refining?: boolean;
  onResult: (id: string, s: RewriteState) => void;
}) {
  const st = useRewrite(
    style,
    original,
    llmUrl,
    enabled,
    language,
    attempt,
    target,
  );
  useEffect(() => {
    onResult(style, st);
  }, [style, st.loading, st.text, st.error, onResult]);

  // A feedback refinement is in flight or applied → show it instead of `st`.
  if (refining)
    return (
      <div className="rewrite__body">
        <TextSkeleton text={override ?? st.text ?? original} />
      </div>
    );
  if (override != null)
    return (
      <div className="rewrite__body">
        {style === "translate" ? (
          <div className="rewrite">{override}</div>
        ) : (
          <DiffText original={original} result={override} />
        )}
      </div>
    );

  if (st.loading)
    return (
      <div className="rewrite__body">
        <TextSkeleton text={original} />
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
            ✓ Already in {target} — nothing to translate.
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
  onRetry,
}: {
  canAccept: boolean;
  acceptText: string;
  nav?: boolean;
  onRetry?: () => void;
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
      {onRetry ? (
        <Button onClick={onRetry}>
          <RefreshCw className="size-3.5" />
          Try again
        </Button>
      ) : (
        <Button onClick={() => send({ type: "dismiss" })}>
          {canAccept ? "Dismiss" : "Close"}
          <Kbd variant="outline" className="-me-1 ms-0.5 text-[10px]">ESC</Kbd>
        </Button>
      )}
      <Button
        variant="brand"
        disabled={!canAccept}
        onClick={() => send({ type: "applyRewrite", text: acceptText })}
      >
        Accept
        <Kbd variant="outline" className="-me-1 ms-0.5 border-white/20 text-[10px] text-[var(--primary-foreground)] group-hover:text-white">TAB</Kbd>
      </Button>
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


/** Number of distinct edits between original and result (contiguous changed
 *  runs count as one), used for the Grammar error badge. */
function countChanges(original: string, result: string): number {
  let count = 0;
  let inChange = false;
  for (const t of diffWords(original, result)) {
    if (t.type === "equal") {
      inChange = false;
    } else if (!inChange) {
      count++;
      inChange = true;
    }
  }
  return count;
}

/** Placeholder shaped like the text being processed: one pulsing bar per word,
 *  roughly sized to the word's length, wrapping like the real sentence. */
function TextSkeleton({ text }: { text: string }) {
  const words = text.trim().split(/\s+/).filter(Boolean);
  return (
    <div className="skeleton" aria-hidden="true">
      {words.map((w, i) => (
        <Skeleton
          key={i}
          className="me-[7px] inline-block h-[0.82em] rounded align-middle"
          style={{ width: `${Math.min(14, Math.max(1.5, w.length))}ch` }}
        />
      ))}
    </div>
  );
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
