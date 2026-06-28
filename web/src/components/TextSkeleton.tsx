import { Skeleton } from "@/components/ui/skeleton";

/** Placeholder shaped like the text being processed: one pulsing bar per word,
 *  sized to the word, on lines as tall as real text (no jump when it resolves). */
export function TextSkeleton({ text }: { text: string }) {
  const words = text.trim().split(/\s+/).filter(Boolean);
  return (
    <div className="text-[15px] leading-[1.45]" aria-hidden="true">
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
