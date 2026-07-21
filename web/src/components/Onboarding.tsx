import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Check, RefreshCw, RotateCcw, X } from "lucide-react";
import { type SettingsState, onSandboxApplied, send } from "@/bridge";
import { ModelCatalog } from "./ModelCatalog";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Kbd, KbdGroup } from "@/components/ui/kbd";
import { Pill } from "@/components/ui/pill";
import { NotavoN } from "./NotavoN";
import { ShaderBackground } from "./ShaderBackground";

const CARD_SHADOW =
  "shadow-[0_6px_16px_rgba(0,0,0,0.4),0_1px_4px_rgba(0,0,0,0.3),inset_0_1px_0_rgba(255,255,255,0.05)]";

// Strong ease-out (Emil): starts fast, settles gently — feels intentional.
const EASE = [0.23, 1, 0.32, 1] as const;

const item = {
  hidden: { opacity: 0, y: 10, filter: "blur(6px)" },
  show: {
    opacity: 1,
    y: 0,
    filter: "blur(0px)",
    transition: { duration: 0.7, ease: EASE },
  },
};

/** Animated first-run onboarding: a glyph + welcome that gives way to a 2-step
 *  setup (Grant Accessibility → Add a model). */
const DEV = import.meta.env.DEV;

export function Onboarding({ state }: { state: SettingsState }) {
  const [phase, setPhase] = useState<"intro" | "setup" | "sandbox" | "done">(
    "intro",
  );
  // Bumped to remount the intro and replay its animation (dev only).
  const [replayKey, setReplayKey] = useState(0);

  // Once both setup steps are satisfied, advance to the hands-on sandbox (a short
  // beat so the second checkmark registers before the transition).
  const setupComplete =
    state.accessibilityTrusted && !!state.model && state.model !== "—";
  useEffect(() => {
    if (phase !== "setup" || !setupComplete) return;
    const t = setTimeout(() => setPhase("sandbox"), 550);
    return () => clearTimeout(t);
  }, [phase, setupComplete]);

  return (
    <div
      className={cn(
        "relative box-border flex h-[500px] w-[440px] flex-col gap-4 overflow-hidden",
        "rounded-[12px] border border-border bg-card p-5 text-[13px] text-subtle",
        CARD_SHADOW,
      )}
    >
      <ShaderBackground className="pointer-events-none absolute inset-0 h-full w-full" />
      {/* Darken the shader under the setup steps so text stays legible. */}
      <AnimatePresence>
        {phase === "setup" && (
          <motion.div
            key="scrim"
            className="pointer-events-none absolute inset-0 bg-card/70"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.4 }}
          />
        )}
      </AnimatePresence>

      {/* Full-width drag strip pinned to the card's top edge — covers the top
          padding too, so grabbing right at the edge works. The top bar sits
          above it (z-20) and handles its own drags. */}
      <div
        className="absolute inset-x-0 top-0 z-10 h-14"
        onMouseDown={() => send({ type: "dragWindow" })}
      />

      {/* Top bar: brand (left) + close (right), persistent across phases.
          Mousedown (not on a button) hands off to a native window drag. */}
      <div
        className="relative z-20 flex cursor-default items-center justify-between"
        onMouseDown={(e) => {
          if (!(e.target as HTMLElement).closest("button")) {
            send({ type: "dragWindow" });
          }
        }}
      >
        <span className="text-[14px] font-semibold tracking-[-0.01em] text-white/90">
          Notavo
        </span>
        <button
          aria-label="Close"
          onClick={() => send({ type: "closeSettings" })}
          className="inline-flex size-7 cursor-pointer items-center justify-center rounded-md text-white/60 transition-colors hover:bg-white/10 hover:text-white"
        >
          <X className="size-4" />
        </button>
      </div>

      <div className="relative z-10 flex flex-1 flex-col">
        <AnimatePresence mode="wait">
          {phase === "intro" ? (
            <Intro key={`intro-${replayKey}`} onStart={() => setPhase("setup")} />
          ) : phase === "setup" ? (
            <Setup key="setup" state={state} />
          ) : phase === "sandbox" ? (
            <Sandbox key="sandbox" onNext={() => setPhase("done")} />
          ) : (
            <Done key="done" onFinish={() => send({ type: "closeSettings" })} />
          )}
        </AnimatePresence>
      </div>

      {phase !== "intro" && <Stepper phase={phase} />}

      {DEV && (
        <button
          onClick={() => {
            setPhase("intro");
            setReplayKey((k) => k + 1);
          }}
          className="absolute bottom-3 left-3 z-20 inline-flex items-center gap-1.5 rounded-md bg-white/10 px-2 py-1 text-[11px] text-white/70 transition-colors hover:bg-white/15 hover:text-white"
        >
          <RotateCcw className="size-3" />
          Replay
        </button>
      )}
    </div>
  );
}

// Bright keycap styling — the default Kbd is too muted against the dark card.
const KEYCAP =
  "h-[20px] min-w-[20px] border border-white/25 bg-white/15 text-[12px] text-foreground " +
  "shadow-[inset_0_1px_0_rgba(255,255,255,0.15),0_1px_2px_rgba(0,0,0,0.4)]";

/** The rephrase shortcut as two separate keycaps: ⌘ + `. */
function Shortcut() {
  return (
    <KbdGroup className="mx-0.5 align-middle">
      <Kbd variant="outline" className={KEYCAP}>
        ⌘
      </Kbd>
      <Kbd variant="outline" className={KEYCAP}>
        `
      </Kbd>
    </KbdGroup>
  );
}

// The named stages shown in the bottom stepper (the intro hero is unlabelled).
const STAGES = [
  { key: "setup", label: "Set up" },
  { key: "sandbox", label: "Try it" },
  { key: "done", label: "Finish" },
];

/** Compact bottom stepper: done stages get a green check, the current one is
 *  highlighted, upcoming ones are dimmed — so the user can see what's next. */
function Stepper({ phase }: { phase: string }) {
  const idx = STAGES.findIndex((s) => s.key === phase);
  if (idx < 0) return null;
  return (
    <motion.div
      initial={{ opacity: 0, y: 6 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.4, ease: EASE }}
      className="relative z-10 flex items-center justify-center gap-2 pb-0.5"
    >
      {STAGES.map((s, i) => (
        <Fragment key={s.key}>
          {i > 0 && (
            <div
              className={cn(
                "h-px w-7 transition-colors duration-300",
                i <= idx ? "bg-white/35" : "bg-white/12",
              )}
            />
          )}
          <div className="flex items-center gap-1.5">
            <span
              className={cn(
                "inline-flex size-[15px] items-center justify-center rounded-full text-[9px] font-semibold transition-colors duration-300",
                i < idx
                  ? "bg-diff-ins text-background"
                  : i === idx
                    ? "bg-white text-background"
                    : "border border-white/25 text-white/40",
              )}
            >
              {i < idx ? <Check className="size-2.5" strokeWidth={3.5} /> : i + 1}
            </span>
            <span
              className={cn(
                "text-[11px] transition-colors duration-300",
                i === idx
                  ? "text-foreground"
                  : i < idx
                    ? "text-white/60"
                    : "text-white/40",
              )}
            >
              {s.label}
            </span>
          </div>
        </Fragment>
      ))}
    </motion.div>
  );
}

// The tagline: typed with a typo, then corrected live (w = typed, r = fixed).
const DEMO = [
  { w: "Write", r: "Write" },
  { w: "with", r: "with" },
  { w: "confidense", r: "confidence" },
];

function Caret() {
  return (
    <motion.span
      className="ml-[1px] inline-block h-[1.05em] w-[2px] translate-y-[0.16em] bg-foreground"
      animate={{ opacity: [1, 1, 0, 0] }}
      transition={{ duration: 1, repeat: Infinity, times: [0, 0.5, 0.5, 1], ease: "linear" }}
    />
  );
}

const WIPE = { duration: 0.38, ease: EASE };

// Each clip wipes left-to-right: hidden (eaten from the right) → shown → gone
// (eaten from the left). A layer is shown only at its stage.
function clipFor(layer: number, stage: number) {
  if (stage < layer) return "inset(0 100% 0 0)"; // not yet
  if (stage === layer) return "inset(0 0 0 0)"; // showing
  return "inset(0 0 0 100%)"; // wiped away
}

// Stages: 0 typed (white) · 1 flagged (red) · 2 corrected (green) · 3 settled (white).
function Word({ d, stage }: { d: { w: string; r: string }; stage: number }) {
  const LAYERS = [
    { text: d.w, className: "text-foreground" },
    {
      text: d.w,
      className:
        "font-semibold text-diff-del underline decoration-diff-del decoration-wavy decoration-2 underline-offset-[3px]",
    },
    { text: d.r, className: "text-diff-ins" },
    { text: d.r, className: "text-foreground" },
  ];
  return (
    <>
      <span className="relative inline-grid align-baseline [grid-template-columns:max-content]">
        {LAYERS.map((l, i) => (
          <motion.span
            key={i}
            className={cn("col-start-1 row-start-1", l.className)}
            initial={false}
            animate={{ clipPath: clipFor(i, stage) }}
            transition={WIPE}
          >
            {l.text}
          </motion.span>
        ))}
      </span>{" "}
    </>
  );
}

/** Types a tagline with a typo, flags it (red squiggle), corrects it (green),
 *  then settles it back to white — a live demo of what Notavo does. */
function TypewriterFix({ onDone }: { onDone: () => void }) {
  const wrong = DEMO.map((d) => d.w).join(" ");
  const [started, setStarted] = useState(false);
  const [typed, setTyped] = useState(0);
  const [stage, setStage] = useState(0);
  const typingDone = typed >= wrong.length;

  // Start typing as the glyph is settling (not after it fully finishes).
  useEffect(() => {
    const t = setTimeout(() => setStarted(true), 650);
    return () => clearTimeout(t);
  }, []);

  // Type out the (wrong) tagline, one character at a time.
  useEffect(() => {
    if (!started || typingDone) return;
    const t = setTimeout(() => setTyped((n) => n + 1), 36);
    return () => clearTimeout(t);
  }, [started, typed, typingDone]);

  // Then run the correction: white → red → green → white. Brisk so users don't wait.
  useEffect(() => {
    if (!typingDone) return;
    const timers = [
      setTimeout(() => setStage(1), 300), // flag the typo (red)
      setTimeout(() => setStage(2), 1050), // correct it (green) — red held ~750ms
      setTimeout(() => setStage(3), 1650), // settle back to white (green held ~600ms)
      setTimeout(() => onDone(), 2050), // reveal CTA once it's white again
    ];
    return () => timers.forEach(clearTimeout);
  }, [typingDone, onDone]);

  if (!typingDone) {
    return (
      <span>
        {wrong.slice(0, typed)}
        <Caret />
      </span>
    );
  }

  return (
    <span>
      {DEMO.map((d, i) =>
        d.w === d.r ? (
          <span key={i}>{d.r} </span>
        ) : (
          <Word key={i} d={d} stage={stage} />
        ),
      )}
    </span>
  );
}

function Intro({ onStart }: { onStart: () => void }) {
  const [revealed, setRevealed] = useState(false);
  const reveal = useCallback(() => setRevealed(true), []);
  return (
    <motion.div
      className="flex flex-1 flex-col text-center"
      initial={{ opacity: 1 }}
      exit={{ opacity: 0, filter: "blur(6px)", transition: { duration: 0.3, ease: EASE } }}
    >
      {/* Hero: glyph + tagline, centered in the space above the CTA. */}
      <div className="flex flex-1 flex-col items-center justify-center gap-6">
        <motion.div
          initial={{ opacity: 0, scale: 1.35, filter: "blur(12px)" }}
          animate={{ opacity: 1, scale: 1, filter: "blur(0px)" }}
          transition={{ duration: 0.85, ease: EASE }}
        >
          <NotavoN className="size-24 text-white [filter:drop-shadow(0_0_26px_rgba(40,133,239,0.45))]" />
        </motion.div>

        {/* Fixed box so the typewriter doesn't reflow the column as it types. */}
        <p className="flex min-h-[1.8em] w-[320px] items-center justify-center text-center text-[19px] leading-relaxed font-medium text-foreground">
          <TypewriterFix onDone={reveal} />
        </p>
      </div>

      {/* CTA (subtitle, then button), lifted up; reserved height so it doesn't
          shift on reveal. */}
      <div className="mb-6 flex h-[104px] flex-col items-center justify-start">
        <AnimatePresence>
          {revealed && (
            <motion.div
              className="flex flex-col items-center gap-4"
              initial="hidden"
              animate="show"
              variants={{ show: { transition: { staggerChildren: 0.12 } } }}
            >
              <motion.p
                variants={item}
                className="max-w-[300px] text-center text-[13px] leading-relaxed text-white/65"
              >
                Everything runs locally on your Mac. Your text is never uploaded
                and never leaves your device.
              </motion.p>
              <motion.div variants={item}>
                <Button size="md" variant="brand" onClick={onStart}>
                  Get started
                </Button>
              </motion.div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </motion.div>
  );
}

function Setup({ state }: { state: SettingsState }) {
  const hasModel = !!state.model && state.model !== "—";
  // With a model already set, "Change" re-expands the download catalog.
  const [browsing, setBrowsing] = useState(false);
  // A new model arrived (download or picker) — collapse the catalog.
  useEffect(() => {
    setBrowsing(false);
  }, [state.model]);
  const catalogOpen = !hasModel || browsing;
  return (
    <motion.div
      className="flex flex-1 flex-col"
      initial="hidden"
      animate="show"
      variants={{ show: { transition: { staggerChildren: 0.09, delayChildren: 0.12 } } }}
    >
      <motion.header variants={item} className="flex flex-col gap-0.5">
        <span className="text-[17px] font-semibold tracking-[-0.01em] text-foreground">
          Finish setup
        </span>
        <span className="text-[12px] text-muted-foreground">
          Two steps and you're set.
        </span>
      </motion.header>

      <div className="mt-2 flex flex-col">
        <motion.div variants={item}>
          <Step
            n={1}
            done={state.accessibilityTrusted}
            title="Grant Accessibility"
            hint={
              state.accessibilityTrusted
                ? "Granted."
                : "Needed to read and edit text in other apps."
            }
            action={
              <Button
                size="sm"
                variant="brand"
                disabled={state.accessibilityTrusted}
                onClick={() => send({ type: "openAccessibility" })}
              >
                {state.accessibilityTrusted ? "Granted" : "Open"}
              </Button>
            }
          />
        </motion.div>
        <motion.div variants={item}>
          <Step
            n={2}
            done={hasModel}
            title="Add an AI model"
            hint={
              hasModel ? (
                <Pill title={state.model}>{state.model}</Pill>
              ) : (
                "Pick one to download — it runs entirely on your Mac."
              )
            }
            action={
              hasModel ? (
                <Button
                  size="sm"
                  variant="default"
                  onClick={() => setBrowsing((b) => !b)}
                >
                  {browsing ? "Close" : "Change"}
                </Button>
              ) : null
            }
          />
          {catalogOpen && (
            <div className="ml-[28px]">
              <ModelCatalog state={state} />
            </div>
          )}
        </motion.div>
      </div>

      <motion.p
        variants={item}
        className="mt-auto border-t border-border pt-3.5 text-[12px] text-muted-foreground"
      >
        Select text in any app, then press <Shortcut />.
      </motion.p>
    </motion.div>
  );
}

/** Hands-on sandbox: two substeps, each teaching one interaction with the real
 *  card. (1) select + ⌘`/pill → rephrase; (2) an auto-underlined mistake → hover
 *  the squiggle → grammar fix. Swift drives the real card via the DOM bridge and
 *  calls `sandboxApplied` when a fix lands, which ticks each checkmark. */
function Sandbox({ onNext }: { onNext: () => void }) {
  const [step, setStep] = useState<1 | 2>(1);
  const [done, setDone] = useState({ s1: false, s2: false });
  const stepRef = useRef(step);
  stepRef.current = step;

  useEffect(() => {
    send({ type: "sandbox", active: true });
    return () => {
      send({ type: "sandbox", active: false });
    };
  }, []);

  // Swift calls this after a rephrase/grammar fix is applied.
  useEffect(() => {
    onSandboxApplied(() => {
      if (stepRef.current === 1) {
        setDone((d) => ({ ...d, s1: true }));
        setTimeout(() => setStep(2), 650);
      } else {
        setDone((d) => ({ ...d, s2: true }));
        setTimeout(onNext, 1050);
      }
    });
  }, [onNext]);

  return (
    <motion.div
      className="flex flex-1 flex-col"
      initial="hidden"
      animate="show"
      variants={{ show: { transition: { staggerChildren: 0.09, delayChildren: 0.1 } } }}
    >
      <motion.header variants={item} className="flex flex-col gap-0.5">
        <span className="text-[17px] font-semibold tracking-[-0.01em] text-foreground">
          Try it out
        </span>
        <span className="text-[12px] text-muted-foreground">
          Two ways Notavo fixes your writing.
        </span>
      </motion.header>

      <div className="mt-1 flex flex-col">
        <motion.div variants={item}>
          <SubStep
            n={1}
            done={done.s1}
            active={step === 1}
            title="Rephrase on demand"
            hint={
              <>
                Select the text you want, then hover the pill or press{" "}
                <Shortcut />.
              </>
            }
          >
            <RephraseField />
          </SubStep>
        </motion.div>
        <motion.div variants={item}>
          <SubStep
            n={2}
            done={done.s2}
            active={step === 2}
            title="Fix mistakes automatically"
            hint="Smaller slips get underlined as you write — hover the squiggle."
          >
            <GrammarField />
          </SubStep>
        </motion.div>
      </div>
    </motion.div>
  );
}

/** One sandbox substep: number → checkmark, with its interactive field revealed
 *  while active (and not yet done). */
function SubStep({
  n,
  done,
  active,
  title,
  hint,
  children,
}: {
  n: number;
  done: boolean;
  active: boolean;
  title: string;
  hint: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <section className="flex gap-2.5 border-t border-border py-3">
      <span
        className={cn(
          "mt-px inline-flex size-[18px] flex-none items-center justify-center rounded-full text-[11px] font-semibold transition-colors",
          done
            ? "bg-diff-ins text-background"
            : active
              ? "bg-[#2885ef] text-white"
              : "border border-border text-muted-foreground",
        )}
      >
        {done ? <Check className="size-3" strokeWidth={3} /> : n}
      </span>
      <div className="flex min-w-0 flex-1 flex-col gap-0.5">
        <span
          className={cn(
            "text-[14px]",
            active || done ? "text-foreground" : "text-muted-foreground",
          )}
        >
          {title}
        </span>
        <span className="text-[12px] text-muted-foreground">{hint}</span>
        <AnimatePresence initial={false}>
          {active && !done && (
            <motion.div
              key="field"
              initial={{ opacity: 0, height: 0 }}
              animate={{ opacity: 1, height: "auto" }}
              exit={{ opacity: 0, height: 0 }}
              transition={{ duration: 0.3, ease: EASE }}
              className="overflow-hidden"
            >
              <div className="pt-2.5">{children}</div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </section>
  );
}

/** Substep 1: a textarea; select + ⌘`/pill opens the real rephrase card. */
function RephraseField() {
  const ref = useRef<HTMLTextAreaElement>(null);
  const [pillTop, setPillTop] = useState<number | null>(null);

  // Place the pill beside the selection's first line. Exact caret geometry in a
  // <textarea> would need a mirror element; line-counting is enough for the demo.
  const updatePill = useCallback(() => {
    const el = ref.current;
    if (!el || el.selectionEnd <= el.selectionStart) {
      setPillTop(null);
      return;
    }
    const cs = getComputedStyle(el);
    const lh = parseFloat(cs.lineHeight) || 20;
    const pt = parseFloat(cs.paddingTop) || 10;
    const line = el.value.slice(0, el.selectionStart).split("\n").length - 1;
    setPillTop(pt + line * lh + lh / 2);
  }, []);

  useEffect(() => {
    const t = setTimeout(() => {
      ref.current?.focus();
      ref.current?.select();
      updatePill();
    }, 350);
    return () => clearTimeout(t);
  }, [updatePill]);

  return (
    <div className="relative">
      <textarea
        ref={ref}
        data-sandbox-input
        autoFocus
        defaultValue="Their going too the store tommorow to buy some grocerys."
        rows={2}
        spellCheck={false}
        onSelect={updatePill}
        className="w-full resize-none rounded-[10px] border border-border bg-black/30 py-2.5 pr-2.5 pl-8 text-[13px] leading-relaxed text-foreground caret-white outline-none transition-colors focus:border-white/25"
      />
      <AnimatePresence>
        {pillTop != null && (
          <motion.button
            key="pill"
            initial={{ opacity: 0, scale: 0.5 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0, scale: 0.5 }}
            transition={{ duration: 0.18, ease: EASE }}
            onMouseEnter={() => send({ type: "sandboxRephrase" })}
            onClick={() => send({ type: "sandboxRephrase" })}
            style={{ top: pillTop }}
            aria-label="Rephrase with Notavo"
            className="absolute left-1.5 z-10 flex size-[20px] -translate-y-1/2 cursor-pointer items-center justify-center rounded-full bg-[#2885ef] text-white shadow-[0_2px_8px_rgba(40,133,239,0.5)] ring-1 ring-white/20 transition-transform hover:scale-110"
          >
            <RefreshCw className="size-3" strokeWidth={2.5} />
          </motion.button>
        )}
      </AnimatePresence>
    </div>
  );
}

// Scripted grammar sample: the typo is pre-underlined; hovering it opens the
// real grammar card with this fix.
const G_BEFORE = "See you ";
const G_TYPO = "tommorow";
const G_AFTER = " — can't wait!";
const G_ORIGINAL = G_BEFORE + G_TYPO + G_AFTER;
const G_CORRECTED = G_BEFORE + "tomorrow" + G_AFTER;

/** Substep 2: a line with an auto-flagged typo (squiggle); hover opens the real
 *  grammar card, anchored at the word. */
function GrammarField() {
  const wordRef = useRef<HTMLSpanElement>(null);
  const open = () => {
    const r = wordRef.current?.getBoundingClientRect();
    if (!r) return;
    send({
      type: "sandboxGrammar",
      original: G_ORIGINAL,
      corrected: G_CORRECTED,
      x: r.left,
      y: r.top,
      w: r.width,
      h: r.height,
    });
  };
  return (
    <div className="rounded-[10px] border border-border bg-black/30 p-2.5 text-[13px] leading-relaxed text-foreground">
      {G_BEFORE}
      <span
        ref={wordRef}
        onMouseEnter={open}
        onClick={open}
        className="cursor-default underline decoration-[#ff6b6b] decoration-wavy decoration-2 underline-offset-[3px]"
      >
        {G_TYPO}
      </span>
      {G_AFTER}
    </div>
  );
}

/** Final onboarding screen: a confirming checkmark + how to start using Notavo. */
function Done({ onFinish }: { onFinish: () => void }) {
  return (
    <motion.div
      className="flex flex-1 flex-col items-center justify-center text-center"
      initial="hidden"
      animate="show"
      variants={{ show: { transition: { staggerChildren: 0.1, delayChildren: 0.05 } } }}
    >
      <motion.div
        variants={item}
        className="mb-5 inline-flex size-16 items-center justify-center rounded-full bg-diff-ins/15 text-diff-ins ring-1 ring-diff-ins/30"
      >
        <motion.span
          initial={{ scale: 0.4, opacity: 0 }}
          animate={{ scale: 1, opacity: 1 }}
          transition={{ duration: 0.5, ease: EASE, delay: 0.15 }}
        >
          <Check className="size-8" strokeWidth={2.5} />
        </motion.span>
      </motion.div>
      <motion.span
        variants={item}
        className="text-[20px] font-semibold tracking-[-0.01em] text-foreground"
      >
        You're all set
      </motion.span>
      <motion.p
        variants={item}
        className="mt-2 max-w-[280px] text-[13px] leading-relaxed text-white/65"
      >
        Select text in any app and press <Shortcut /> to check grammar or
        rewrite it.
      </motion.p>
      <motion.div variants={item} className="mt-6">
        <Button size="md" variant="brand" onClick={onFinish}>
          Start writing
        </Button>
      </motion.div>
    </motion.div>
  );
}

function Step({
  n,
  done,
  title,
  hint,
  action,
}: {
  n: number;
  done: boolean;
  title: string;
  hint: React.ReactNode;
  action: React.ReactNode;
}) {
  return (
    <section className="flex items-center justify-between gap-3 border-t border-border py-3.5">
      <div className="flex min-w-0 items-start gap-2.5">
        <span
          className={cn(
            "mt-px inline-flex size-[18px] flex-none items-center justify-center rounded-full text-[11px] font-semibold transition-colors",
            done
              ? "bg-diff-ins text-background"
              : "border border-border text-muted-foreground",
          )}
        >
          {done ? <Check className="size-3" strokeWidth={3} /> : n}
        </span>
        <div className="flex min-w-0 flex-col gap-0.5">
          <span className="text-[14px] text-foreground">{title}</span>
          <span className="text-[12px] text-muted-foreground [overflow-wrap:anywhere]">
            {hint}
          </span>
        </div>
      </div>
      {action}
    </section>
  );
}
