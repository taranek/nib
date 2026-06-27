import { franc } from "franc-min";

// franc returns ISO 639-3 codes; map the common ones to language names we can
// drop into a prompt. Unknown/undetermined → null (prompt falls back to "the
// same language as the input").
const NAMES: Record<string, string> = {
  eng: "English",
  pol: "Polish",
  spa: "Spanish",
  deu: "German",
  fra: "French",
  ita: "Italian",
  por: "Portuguese",
  nld: "Dutch",
  rus: "Russian",
  ukr: "Ukrainian",
  ces: "Czech",
  slk: "Slovak",
  slv: "Slovene",
  hrv: "Croatian",
  srp: "Serbian",
  bul: "Bulgarian",
  ron: "Romanian",
  hun: "Hungarian",
  swe: "Swedish",
  nob: "Norwegian",
  dan: "Danish",
  fin: "Finnish",
  ell: "Greek",
  tur: "Turkish",
  lit: "Lithuanian",
  lav: "Latvian",
  est: "Estonian",
  cat: "Catalan",
  jpn: "Japanese",
  kor: "Korean",
  cmn: "Chinese",
  arb: "Arabic",
  heb: "Hebrew",
  hin: "Hindi",
  ben: "Bengali",
  vie: "Vietnamese",
  tha: "Thai",
  ind: "Indonesian",
};

/** Detect the text's language name (e.g. "Polish") via franc-min — free, sync,
 *  zero tokens. Returns null when undetermined or unmapped. */
export function detectLanguageName(text: string): string | null {
  const code = franc(text, { minLength: 10 }); // ISO 639-3, or 'und'
  if (code === "und") return null;
  return NAMES[code] ?? null;
}
