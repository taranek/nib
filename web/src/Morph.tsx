import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { motion, useReducedMotion } from "motion/react";
import { RefreshCw } from "lucide-react";
import { ThinkingOrb } from "thinking-orbs";
import { type MorphRect, type MorphState, onSetMorph, send } from "./bridge";
import { CardContent } from "@/components/Card";

/** Fixed card width (matches App.tsx). Height is measured and reported so Swift
 *  can size + place the card rect. */
const CARD_W = 440;

/** Frame-time profiler for the morph animations: while `phase` is non-null a
 *  rAF loop records inter-frame deltas; when the phase ends, one report goes to
 *  Swift's log. Long deltas = the WebContent process is janking (style/layout/
 *  paint); clean deltas while the eye sees stutter = compositor/native side. */
function useAnimPerf(phase: string | null, rendersRef: React.RefObject<number>) {
  useEffect(() => {
    if (!phase) return;
    const deltas: number[] = [];
    const startRenders = rendersRef.current ?? 0;
    let last = performance.now();
    let raf = 0;
    const tick = () => {
      const now = performance.now();
      deltas.push(now - last);
      last = now;
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    const t0 = performance.now();
    return () => {
      cancelAnimationFrame(raf);
      if (deltas.length < 2) return;
      const worst = Math.max(...deltas.slice(1));
      const avg = deltas.reduce((a, b) => a + b, 0) / deltas.length;
      const dropped = deltas.filter((d) => d > 25).length / deltas.length;
      send({
        type: "morphPerf",
        phase,
        frames: deltas.length,
        worstMs: Math.round(worst),
        avgMs: Math.round(avg * 10) / 10,
        droppedPct: Math.round(dropped * 100),
        renders: (rendersRef.current ?? 0) - startRenders,
        totalMs: Math.round(performance.now() - t0),
      });
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phase]);
}

/** Transform-origin for the card: the pill's centre, expressed in the card's
 *  local space and clamped inside it — so the scale entrance visibly emanates
 *  from the trigger wherever the card lands (below, above, flipped). */
function originAt(pill: MorphRect | null, card: MorphRect): string {
  if (!pill) return "top left";
  const x = Math.min(Math.max(pill.x + pill.w / 2 - card.x, 0), card.w);
  const y = Math.min(Math.max(pill.y + pill.h / 2 - card.y, 0), card.h);
  return `${x}px ${y}px`;
}

/** Shared surface for the pill disc and the card, so the bud reads as the same
 *  material. Matches --card. */
const SURFACE = "#191a1b";
const SHADOW =
  "0 6px 20px rgba(0,0,0,0.42), inset 0 0 0 1px rgba(255,255,255,0.14)";

/** The unified overlay surface: one full-desktop transparent webview drawing
 *  the pill and the card in one DOM. The pill stays put; the card scales out of
 *  it, transform-origin pinned at the trigger. (An SVG goo filter once bridged
 *  the two, but WebKit runs SVG filter chains on the CPU and shifts their
 *  colours to linearRGB — laggy and green-tinted — so: plain divs, GPU-only
 *  transform/opacity.) */
export function Morph() {
  const [morph, setMorph] = useState<MorphState | null>(null);
  // The card outlives Swift's clear by one beat so the close can play.
  const [shownCard, setShownCard] = useState<MorphState["card"] | null>(null);
  const measureRef = useRef<HTMLDivElement>(null);
  const reduced = useReducedMotion();

  useEffect(() => {
    onSetMorph(setMorph);
    // Plain-browser dev (no Swift host): seed a pill + open card so the surface
    // can be exercised and inspected with devtools.
    if (!window.webkit?.messageHandlers) {
      setMorph({
        pill: { visible: true, state: "idle", rect: { x: 180, y: 194, w: 16, h: 16 } },
        card: {
          data: {
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
            explainFixes: true,
          },
          rect: { x: 200, y: 220, w: 440, h: 280 },
        },
      });
    }
  }, []);

  const pill = morph?.pill;
  const open = !!morph?.card?.data && !!morph.card.rect;

  // Identity of the card CONTENT (not the object — Swift pushes a fresh object
  // on every state change, and re-adopting each one re-rendered CardContent in
  // a storm: slow, and the tab highlight re-measured itself into jitter).
  const cardKey = morph?.card?.data
    ? `${morph.card.data.mode}|${morph.card.data.original}`
    : null;
  const shownKey = shownCard?.data
    ? `${shownCard.data.mode}|${shownCard.data.original}`
    : null;

  // Adopt a card only when its content identity changes; on clear, keep the
  // last one mounted while the shrink-back plays (see onAnimationComplete).
  useEffect(() => {
    if (open && cardKey !== shownKey) setShownCard(morph!.card);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, cardKey]);

  // Report the card content's natural height so Swift can size the card rect —
  // but only when it actually changed, or the report→reposition→push cycle
  // becomes a feedback loop.
  const lastReported = useRef(0);
  useLayoutEffect(() => {
    const el = measureRef.current;
    if (!el || !shownCard?.data) return;
    const report = () => {
      const h = Math.ceil(el.offsetHeight);
      if (h === lastReported.current) return;
      lastReported.current = h;
      send({ type: "resize", width: CARD_W, height: h });
    };
    report();
    const ro = new ResizeObserver(report);
    ro.observe(el);
    return () => ro.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [shownKey]);

  const cardRect: MorphRect | null = open
    ? morph!.card.rect
    : (shownCard?.rect ?? null);

  // Perf diagnosis: count renders and profile frame times per animation phase.
  const renders = useRef(0);
  renders.current += 1;
  useAnimPerf(
    open ? "open" : shownCard?.data ? "close" : null,
    renders,
  );

  return (
    <div style={{ position: "fixed", inset: 0, pointerEvents: "none" }}>
      {/* The trigger: its own disc, stays put the whole time. */}
      {pill?.visible && pill.rect && (
        <div
          style={{
            position: "absolute",
            left: pill.rect.x,
            top: pill.rect.y,
            width: pill.rect.w,
            height: pill.rect.h,
            borderRadius: 999,
            background: SURFACE,
            boxShadow: SHADOW,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <PillGlyph
            state={pill.state}
            size={Math.min(pill.rect.w, pill.rect.h)}
          />
        </div>
      )}

      {/* The card: scales out of the trigger — transform-origin pinned to where
          the pill sits relative to the card, transform+opacity only (GPU).
          Structure mirrors the old App.tsx card exactly: CardContent in normal
          flow, the card sized by its content (no pixel height, no absolute
          wrapper) — the tab highlight's layout animation measures a stable
          normal-flow tree, which is what it was built against. Swift's rect is
          used for position and origin only; height flows from content and is
          reported back for positioning. */}
      {shownCard?.data && cardRect && (
        <motion.div
          data-morph-blob
          key={shownKey ?? "card"}
          initial={reduced ? { opacity: 0 } : { scale: 0.92, opacity: 0 }}
          animate={
            open
              ? { scale: 1, opacity: 1 }
              : reduced
                ? { opacity: 0 }
                : { scale: 0.92, opacity: 0 }
          }
          transition={
            reduced
              ? { duration: 0.15 }
              : open
                ? { type: "spring", duration: 0.3, bounce: 0.15 }
                // Dismissal: a fast tween, not a spring — the user asked it to
                // leave; a settle tail here just reads as lag.
                : { duration: 0.13, ease: "easeOut" }
          }
          onAnimationComplete={() => {
            if (!open) setShownCard(null);   // close finished — unmount
          }}
          ref={measureRef}
          style={{
            position: "absolute",
            left: cardRect.x,
            top: cardRect.y,
            width: CARD_W,
            transformOrigin: originAt(pill?.rect ?? null, cardRect),
            borderRadius: 14,
            overflow: "hidden",
            background: SURFACE,
            boxShadow: SHADOW,
            // Clicks must reach the card UI; the window's click-through is
            // gated natively around the card rect.
            pointerEvents: open ? "auto" : "none",
          }}
        >
          <CardContent card={shownCard.data} />
        </motion.div>
      )}
    </div>
  );
}

/** The pill's glyph: blue refresh disc when no model is ready, else the orb. */
function PillGlyph({
  state,
  size,
}: {
  state: MorphState["pill"]["state"];
  size: number;
}) {
  const scale = Math.min(1, Math.max(0.4, (size - 2) / 20));
  if (state === "plain") {
    return (
      <div
        style={{
          width: 18,
          height: 18,
          borderRadius: 999,
          background: "#2885ef",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <RefreshCw className="size-[10px] text-white" strokeWidth={2.5} />
      </div>
    );
  }
  return (
    <div style={{ transform: `scale(${scale})`, lineHeight: 0 }}>
      {/* The orb is a canvas redrawn every frame while unpaused — on this
          always-mounted desktop-sized surface that's constant compositing, so
          it only animates while a check is actually running. */}
      <ThinkingOrb
        state="breathing"
        size={20}
        speed={1.3}
        theme="dark"
        paused={state !== "loading"}
        aria-label="Nib is checking"
      />
    </div>
  );
}
