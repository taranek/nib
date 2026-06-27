import { franc } from "franc-min";

/** Free, zero-token language check via franc-min (n-gram detection). Biased
 *  toward English (the default): franc is unreliable on short, plain-ASCII text,
 *  so only switch to Translate on a non-ASCII signal or longer, confidently
 *  non-English text. */
export function looksEnglish(text: string): boolean {
  const lang = franc(text, { minLength: 10 }); // ISO 639-3, or 'und' if unsure
  if (lang === "eng" || lang === "und") return true;
  const hasNonAscii = [...text].some((c) => c.charCodeAt(0) > 127);
  if (!hasNonAscii && text.length < 40) return true; // short ASCII -> assume English
  return false;
}
