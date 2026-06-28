import { diffWords } from "@/lib/diff";

const TONE = {
  equal: "text-[var(--text-secondary)]",
  del: "text-[var(--diff-del)] line-through",
  ins: "text-[var(--diff-ins)] font-semibold",
} as const;

/** Inline word diff: removed words struck-through red, added words green. */
export function DiffText({
  original,
  result,
}: {
  original: string;
  result: string;
}) {
  return (
    <div className="text-[15px] leading-[1.45] text-[var(--text-secondary)]">
      {diffWords(original, result).map((t, i) => (
        <span key={i}>
          <span className={TONE[t.type]}>{t.text}</span>{" "}
        </span>
      ))}
    </div>
  );
}
