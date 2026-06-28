import { useCallback, useEffect, useState } from "react";
import { ArrowUp, Check, Loader2, RefreshCw } from "lucide-react";
import { type CardData, send } from "@/bridge";
import {
  type ChatMsg,
  type RewriteState,
  chatRefine,
  refineSystem,
  useLanguage,
  useRewrite,
} from "@/useRewrite";
import {
  Tabs,
  TabsContent,
  TabsContents,
  TabsList,
  TabsTrigger,
} from "@/components/ui/motion-tabs";
import { Button } from "@/components/ui/button";
import { Kbd } from "@/components/ui/kbd";
import { Chip } from "@/components/ui/chip";
import { IconButton } from "@/components/ui/icon-button";
import { countChanges } from "@/lib/diff";
import { DiffText } from "./DiffText";
import { TextSkeleton } from "./TextSkeleton";

// Quick-filter edits shown as chips above the composer (Rephrase tab).
const CHIPS: { label: string; instruction: string }[] = [
  {
    label: "Shorten",
    instruction:
      "Make it noticeably shorter and more concise — cut filler words and tighten the phrasing.",
  },
  {
    label: "Expand",
    instruction:
      "Add a concrete detail or example so the text is clearly longer and more descriptive.",
  },
  {
    label: "More formal",
    instruction:
      "Rewrite in a formal, professional register; avoid contractions and casual phrasing.",
  },
  {
    label: "Confident",
    instruction:
      "Rewrite it assertively and confidently; remove hedging words like 'sometimes', 'maybe', and 'I think'.",
  },
];

const CONTENT = "px-2 py-3";
const BODY = "min-h-[22px] pl-2";
const RESULT = "text-[15px] leading-[1.45] text-[var(--text-secondary)]";
const TAB_KBD =
  "-me-1 ms-0.5 border-white/20 text-[10px] text-[var(--primary-foreground)] group-hover:text-white";

export function CardContent({ card }: { card: CardData }) {
  return card.mode === "grammar" ? (
    <GrammarBody card={card} />
  ) : (
    <RewriteBody card={card} />
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
      <div className={CONTENT}>
        <DiffText original={card.original} result={card.result} />
      </div>
      <div className="flex items-center justify-end gap-2 p-2">
        <Button
          variant="brand"
          disabled={!canAccept}
          onClick={() => send({ type: "applyRewrite", text: card.result })}
        >
          Accept
          <Kbd variant="outline" className={TAB_KBD}>
            TAB
          </Kbd>
        </Button>
      </div>
    </>
  );
}

function RewriteBody({ card }: { card: CardData }) {
  const [active, setActive] = useState(card.styles[0]?.id ?? "grammar");
  const [results, setResults] = useState<Record<string, RewriteState>>({});
  const [attempts, setAttempts] = useState<Record<string, number>>({});
  const [refined, setRefined] = useState<Record<string, string>>({});
  // Per-style refine conversation so custom prompts accumulate; retry replays.
  const [chats, setChats] = useState<Record<string, ChatMsg[]>>({});
  const [refiningStyle, setRefiningStyle] = useState<string | null>(null);
  const [feedback, setFeedback] = useState("");
  const [activeChip, setActiveChip] = useState<string | null>(null);
  const onResult = useCallback(
    (id: string, s: RewriteState) => setResults((p) => ({ ...p, [id]: s })),
    [],
  );

  const visibleStyles = card.styles;
  const visibleIds = visibleStyles.map((s) => s.id).join("|");
  const current = active;

  // Detect the language so Rephrase replies in it (waits for it); Grammar/
  // Translate don't need it.
  const { loading: langLoading, lang: language } = useLanguage(
    card.original,
    card.llmUrl,
    card.ready,
  );
  const needsLang = (id: string) => id === "rephrase";

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

  // ←/→ cycle the tabs (skipped while an input is focused — the composer handles
  // its own arrows so it can cycle too).
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
  const activeText = refined[current] ?? activeRes?.text ?? "";
  const canAccept =
    !refining &&
    (refined[current] != null ||
      (!!activeRes && !activeRes.loading && !activeRes.error)) &&
    activeText !== "" &&
    activeText.trim() !== card.original.trim();

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

  // `reset` (chips) starts a fresh conversation from the original; otherwise it
  // continues the existing one (custom prompts accumulate).
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

  // Try again: replay the last conversation turn for a variation, else
  // regenerate the base tab.
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

  const submitFeedback = useCallback(() => {
    const instruction = feedback.trim();
    if (!instruction) return;
    setFeedback("");
    setActiveChip(null);
    runInstruction(instruction, refined[current] ?? activeRes?.text, false);
  }, [feedback, runInstruction, refined, activeRes, current]);

  // Tab accepts, Esc dismisses (ignored while the composer is focused).
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
        <div className={CONTENT}>
          <div className={`${RESULT} text-muted-foreground italic`}>
            Model still loading…
          </div>
        </div>
        <div className="flex items-center justify-end gap-2 p-2">
          <Button variant="brand" disabled>
            Accept
            <Kbd variant="outline" className={TAB_KBD}>
              TAB
            </Kbd>
          </Button>
        </div>
      </>
    );
  }

  return (
    <>
      <Tabs value={current} onValueChange={setActive} className="gap-0">
        <div className="flex items-center justify-between gap-2 border-b border-border p-2">
          <TabsList
            className="h-7 bg-transparent p-0"
            activeClassName="bg-accent shadow-none ring-1 ring-border"
          >
            {visibleStyles.map((s) => {
              const r = results[s.id];
              const ready = !!r && !r.loading && !r.error;
              const unchanged = ready && r.text.trim() === card.original.trim();
              const ok = s.id === "grammar" && unchanged;
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
                    <span className="inline-flex h-[15px] min-w-[15px] items-center justify-center rounded-full bg-destructive px-1 text-[10px] leading-none font-semibold text-white tabular-nums">
                      {errors > 9 ? "9+" : errors}
                    </span>
                  )}
                </TabsTrigger>
              );
            })}
          </TabsList>
          {current !== "grammar" && (
            <IconButton aria-label="Try again" onClick={retry}>
              <RefreshCw className="size-3.5" />
            </IconButton>
          )}
        </div>
        <div className={CONTENT}>
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
        <div className="flex flex-wrap gap-1.5 pt-2.5 pr-2 pb-0 pl-3">
          {CHIPS.map((c) => (
            <Chip
              key={c.label}
              active={activeChip === c.label}
              disabled={refining}
              onClick={() => {
                setActiveChip(c.label);
                runInstruction(c.instruction, card.original, true);
              }}
            >
              {c.label}
            </Chip>
          ))}
        </div>
      )}

      <div className="flex items-center justify-end gap-2 p-2">
        {current === "rephrase" && (
          <>
            <input
              className="ml-2 min-w-0 flex-1 border-none bg-transparent p-0 text-[13px] text-foreground outline-none placeholder:text-muted-foreground"
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
                  e.preventDefault();
                  cycle(-1);
                } else if (e.key === "ArrowRight") {
                  e.preventDefault();
                  cycle(1);
                }
              }}
            />
            <IconButton
              aria-label="Send feedback"
              disabled={refining || !feedback.trim()}
              onClick={submitFeedback}
            >
              {refining ? (
                <Loader2 className="size-3.5 animate-spin" />
              ) : (
                <ArrowUp className="size-3.5" />
              )}
            </IconButton>
          </>
        )}
        <Button
          variant="brand"
          disabled={!canAccept}
          onClick={() => send({ type: "applyRewrite", text: activeText })}
        >
          Accept
          <Kbd variant="outline" className={TAB_KBD}>
            TAB
          </Kbd>
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
  const st = useRewrite(style, original, llmUrl, enabled, language, attempt, target);
  useEffect(() => {
    onResult(style, st);
  }, [style, st.loading, st.text, st.error, onResult]);

  if (refining)
    return (
      <div className={BODY}>
        <TextSkeleton text={override ?? st.text ?? original} />
      </div>
    );
  if (override != null)
    return (
      <div className={BODY}>
        {style === "translate" ? (
          <div className={RESULT}>{override}</div>
        ) : (
          <DiffText original={original} result={override} />
        )}
      </div>
    );
  if (st.loading)
    return (
      <div className={BODY}>
        <TextSkeleton text={original} />
      </div>
    );
  if (st.error)
    return (
      <div className={BODY}>
        <div className={`${RESULT} text-muted-foreground italic`}>
          Couldn't reach the model.
        </div>
      </div>
    );
  if (style === "translate")
    return (
      <div className={BODY}>
        {st.text.trim() === original.trim() ? (
          <div className="text-[14px] text-[var(--diff-ins)]">
            ✓ Already in {target} — nothing to translate.
          </div>
        ) : (
          <div className={RESULT}>{st.text}</div>
        )}
      </div>
    );
  if (st.text.trim() === original.trim())
    return (
      <div className={BODY}>
        <div className="text-[14px] text-[var(--diff-ins)]">
          ✓ Looks good — no changes needed.
        </div>
      </div>
    );
  return (
    <div className={BODY}>
      <DiffText original={original} result={st.text} />
    </div>
  );
}
