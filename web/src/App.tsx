import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { motion } from "motion/react";
import { type CardData, onSetCard, send } from "./bridge";
import { CardContent } from "@/components/Card";

// Soft card shadow (matches the settings card).
const CARD_SHADOW =
  "shadow-[0_6px_16px_rgba(0,0,0,0.4),0_1px_4px_rgba(0,0,0,0.3),inset_0_1px_0_rgba(255,255,255,0.05)]";

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
    // The padding is the card's transparent shadow margin; clicking it (around
    // the card) counts as clicking outside → dismiss.
    <div
      className="w-max p-6"
      ref={wrapRef}
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) send({ type: "dismiss" });
      }}
    >
      {/* Origin-aware entrance: the card's top-left is pinned to the anchor, so
          it scales out of the trigger. Keyed on the card identity so it replays
          per new card, not on tab switches. */}
      <motion.div
        key={`${card.mode}|${card.original}`}
        className={`w-[440px] overflow-hidden rounded-[12px] bg-card text-[var(--text-secondary)] ${CARD_SHADOW}`}
        style={{ transformOrigin: "top left" }}
        initial={{ opacity: 0, scale: 0.96 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ type: "spring", duration: 0.22, bounce: 0.2 }}
      >
        <CardContent card={card} />
      </motion.div>
    </div>
  );
}
