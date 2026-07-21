export type DiffTok = { text: string; type: "equal" | "del" | "ins" };

/** Word-level LCS diff: removed words struck-through, added words highlighted. */
export function diffWords(aStr: string, bStr: string): DiffTok[] {
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
        a[i] === b[j]
          ? dp[i + 1][j + 1] + 1
          : Math.max(dp[i + 1][j], dp[i][j + 1]);
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

/** Contiguous changed runs as (from → to) pairs, e.g. "found" → "find".
 *  Pure insertions/removals have an empty `from`/`to`. */
export function changedPairs(
  original: string,
  result: string,
): { from: string; to: string }[] {
  const pairs: { from: string; to: string }[] = [];
  let del: string[] = [];
  let ins: string[] = [];
  const flush = () => {
    if (del.length || ins.length)
      pairs.push({ from: del.join(" "), to: ins.join(" ") });
    del = [];
    ins = [];
  };
  for (const t of diffWords(original, result)) {
    if (t.type === "equal") flush();
    else (t.type === "del" ? del : ins).push(t.text);
  }
  flush();
  return pairs;
}

/** Number of distinct edits between original and result (contiguous changed
 *  runs count as one), used for the Grammar error badge. */
export function countChanges(original: string, result: string): number {
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
