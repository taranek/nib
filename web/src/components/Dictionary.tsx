import { useMemo, useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Plus, Search, X } from "lucide-react";
import { send } from "@/bridge";
import { Button } from "@/components/ui/button";

/** Personal dictionary: words Nib should never flag — project names, people,
 *  jargon. Reached from Settings and shown in its place, like the app list.
 *  Swift owns the list; every change round-trips and comes back in the next
 *  settings push, so this component only holds the draft input. */
export function Dictionary({ words }: { words: string[] }) {
  const [draft, setDraft] = useState("");
  const trimmed = draft.trim();
  const exists = useMemo(
    () => words.some((w) => w.toLowerCase() === trimmed.toLowerCase()),
    [words, trimmed],
  );
  // The input doubles as a filter once the list is long enough to need one.
  const shown = useMemo(() => {
    const q = trimmed.toLowerCase();
    return q ? words.filter((w) => w.toLowerCase().includes(q)) : words;
  }, [words, trimmed]);

  const add = () => {
    if (!trimmed || exists || /\s/.test(trimmed)) return;
    send({ type: "addKnownWord", word: trimmed });
    setDraft("");
  };

  return (
    <>
      <div className="flex flex-col gap-2.5 border-t border-border pt-3.5">
        <span className="text-[12px] text-muted-foreground">
          Words Nib should never flag — project names, people, jargon.
          Case doesn’t matter.
        </span>
        <form
          className="flex items-center gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            add();
          }}
        >
          <div className="group/field flex min-w-0 flex-1 items-center gap-2 rounded-md border border-border px-2 py-1.5 transition-[border-color,background-color] duration-150 hover:not-focus-within:border-hairline-strong focus-within:border-white/25 focus-within:bg-black/20">
            {words.length > 8 ? (
              <Search className="size-3.5 shrink-0 text-muted-foreground transition-colors duration-150 group-focus-within/field:text-foreground" />
            ) : (
              <Plus className="size-3.5 shrink-0 text-muted-foreground transition-colors duration-150 group-focus-within/field:text-foreground" />
            )}
            <input
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              placeholder="Add a word"
              spellCheck={false}
              autoCorrect="off"
              autoCapitalize="off"
              className="min-w-0 flex-1 border-none bg-transparent p-0 text-[13px] text-foreground outline-none placeholder:text-muted-foreground"
            />
          </div>
          <Button
            type="submit"
            size="sm"
            variant="brand"
            disabled={!trimmed || exists || /\s/.test(trimmed)}
          >
            Add
          </Button>
        </form>
        {trimmed && (exists || /\s/.test(trimmed)) && (
          <span className="text-[11px] text-muted-foreground">
            {exists ? "Already in your dictionary." : "One word at a time."}
          </span>
        )}
      </div>

      <div className="scroll-mask-y thin-scroll-xs -mr-4 flex max-h-[360px] flex-col overflow-y-auto overscroll-contain pr-3">
        {words.length === 0 ? (
          <span className="py-3 text-[13px] text-muted-foreground">
            No words yet. Add one here, or hover a squiggle and choose “Add to
            dictionary”.
          </span>
        ) : shown.length === 0 ? (
          <span className="py-3 text-[13px] text-muted-foreground">
            “{trimmed}” isn’t in your dictionary — press Add.
          </span>
        ) : (
          <AnimatePresence initial={false}>
            {shown.map((w) => (
              // Enter/exit animate the row's own height (overflow clipped), so
              // the rows below follow in normal flow. No `layout`: its sibling
              // transforms briefly overflow the scroller and flash a scrollbar.
              <motion.div
                key={w.toLowerCase()}
                initial={{ opacity: 0, height: 0 }}
                animate={{ opacity: 1, height: "auto" }}
                exit={{ opacity: 0, height: 0 }}
                transition={{ duration: 0.16, ease: "easeOut" }}
                className="overflow-hidden"
              >
                <div className="group flex items-center gap-2 rounded-md py-1 pl-2 pr-1 transition-colors hover:bg-white/[0.03]">
                <span className="min-w-0 flex-1 truncate text-[13px] text-foreground">
                  {w}
                </span>
                <button
                  type="button"
                  aria-label={`Remove ${w}`}
                  title="Remove"
                  onClick={() => send({ type: "removeKnownWord", word: w })}
                  className="flex size-6 items-center justify-center rounded text-muted-foreground opacity-60 transition hover:bg-white/[0.06] hover:text-foreground group-hover:opacity-100"
                >
                  <X className="size-3.5" />
                </button>
                </div>
              </motion.div>
            ))}
          </AnimatePresence>
        )}
      </div>
    </>
  );
}
