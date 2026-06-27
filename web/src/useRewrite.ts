import { useEffect, useState } from "react";

// The rewrite styles' instructions, mirrored from the Swift RewriteStyle enum.
// (We fetch the local LLM directly from the webview, so the prompts live here.)
// Keep abbreviations, jargon, names, and code intact across every style — e.g.
// don't turn "config" into "configuration" or "repo" into "repository".
const KEEP_TERMS =
  " Keep abbreviations, acronyms, technical terms, names, and code exactly as " +
  "written — never expand or replace them (e.g. keep 'config', 'repo', 'API').";

const INSTRUCTIONS: Record<string, string> = {
  grammar:
    "Correct only the spelling, grammar, and punctuation in the user's text, " +
    "changing as little as possible. Keep the original wording, meaning, tone, " +
    "and length. If there are no errors, return the text unchanged." +
    KEEP_TERMS +
    " Put the result in the 'rewrite' field.",
  rephrase:
    "Rephrase the user's text using different wording while keeping the same " +
    "meaning and language, in clear, natural prose." +
    KEEP_TERMS +
    " Put the result in the 'rewrite' field.",
  shorten:
    "Make the user's text more concise: keep the same meaning and language but " +
    "use fewer words." +
    KEEP_TERMS +
    " Put the result in the 'rewrite' field.",
  translate:
    "Translate the user's text into English. Detect the source language " +
    "automatically and produce natural, fluent English that preserves the meaning " +
    "and tone. If the text is already English, return it unchanged." +
    KEEP_TERMS +
    " Put the result in the 'rewrite' field.",
};

// Constrain output to JSON so the small model returns the answer directly.
const SCHEMA = {
  type: "json_schema",
  json_schema: {
    name: "rewrite",
    strict: true,
    schema: {
      type: "object",
      properties: { rewrite: { type: "string" } },
      required: ["rewrite"],
    },
  },
};

// "Try again" rotates through these angles (a small model barely varies on
// temperature alone, so we steer the prompt) — cycled by attempt number.
const RETRY_NUDGES = [
  " Give a different alternative — vary the wording.",
  " Use a noticeably more formal, polished tone.",
  " Use a more casual, conversational tone.",
  " Make it more concise and direct.",
  " Use more vivid, expressive language.",
];

// Module-level cache (style|text → result) so re-tabbing / re-mounting is instant.
const cache = new Map<string, string>();

async function fetchRewrite(
  style: string,
  text: string,
  llmUrl: string,
  language: string | null,
  attempt: number,
  target: string,
): Promise<string | null> {
  let instruction = INSTRUCTIONS[style] ?? INSTRUCTIONS.grammar;
  // Translate goes to the user's chosen target language.
  if (style === "translate") {
    instruction =
      `Translate the user's text into ${target}. Detect the source language ` +
      `automatically and produce natural, fluent ${target} that preserves the ` +
      `meaning and tone. If the text is already in ${target}, return it unchanged.` +
      KEEP_TERMS +
      " Put the result in the 'rewrite' field.";
  }
  // Grammar/Rephrase/Shorten respond in the text's own language; reinforce the
  // detected one so a small model doesn't drift to English.
  if (style !== "translate" && language) {
    instruction +=
      ` The text is written in ${language}. Write the result in ${language} — ` +
      `do NOT translate it into English or any other language.`;
  }
  // First pass is deterministic (temp 0). "Try again" passes attempt>0, which
  // rotates a prompt nudge (the real lever for variety on a small model) and
  // raises the temperature + varies the seed.
  const retry = attempt > 0;
  if (retry) {
    instruction += RETRY_NUDGES[(attempt - 1) % RETRY_NUDGES.length];
  }
  try {
    const res = await fetch(llmUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messages: [
          { role: "system", content: instruction },
          { role: "user", content: text },
        ],
        temperature: retry ? 0.8 : 0,
        ...(retry ? { seed: attempt, top_p: 0.95 } : {}),
        max_tokens: 1024,
        response_format: SCHEMA,
      }),
    });
    if (!res.ok) return null;
    const data = await res.json();
    const content: string | undefined = data?.choices?.[0]?.message?.content;
    if (!content) return null;
    const json = content.replace(/```json|```/g, "").trim();
    const parsed = JSON.parse(json);
    const out = (parsed?.rewrite ?? "").trim();
    return out || null;
  } catch {
    return null;
  }
}

export type ChatMsg = { role: "system" | "user" | "assistant"; content: string };

/** System prompt for the refine conversation — edits accumulate across turns. */
export function refineSystem(language: string | null): string {
  let s =
    "You revise the user's text step by step. Apply each new instruction ON TOP " +
    "of your previous result, keeping all earlier changes plus the original " +
    "meaning and language unless told otherwise." +
    KEEP_TERMS +
    " Each turn, return the COMPLETE revised text in the 'rewrite' field.";
  if (language) {
    s += ` The text is written in ${language}; keep results in ${language} unless asked otherwise.`;
  }
  return s;
}

/** Run a refine conversation (system + alternating user/assistant turns) so the
 *  model has the full history of instructions and its own prior results. */
export async function chatRefine(
  messages: ChatMsg[],
  llmUrl: string,
): Promise<string | null> {
  try {
    const res = await fetch(llmUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messages,
        temperature: 0.4,
        max_tokens: 1024,
        response_format: SCHEMA,
      }),
    });
    if (!res.ok) return null;
    const data = await res.json();
    const content: string | undefined = data?.choices?.[0]?.message?.content;
    if (!content) return null;
    const parsed = JSON.parse(content.replace(/```json|```/g, "").trim());
    const out = (parsed?.rewrite ?? "").trim();
    return out || null;
  } catch {
    return null;
  }
}

// ── Language detection ──────────────────────────────────────────────────────
// A tiny LLM call (a few tokens) returning the language's English name. The model
// detects more reliably than a client-side n-gram lib, and naming the language is
// the only thing that stops a small model translating rewrites to English.

const LANG_SCHEMA = {
  type: "json_schema",
  json_schema: {
    name: "language",
    strict: true,
    schema: {
      type: "object",
      properties: { language: { type: "string" } },
      required: ["language"],
    },
  },
};

const langCache = new Map<string, string | null>();

async function fetchLanguage(
  text: string,
  llmUrl: string,
): Promise<string | null> {
  try {
    const res = await fetch(llmUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messages: [
          {
            role: "system",
            content:
              "Identify the language of the user's text. Respond with the " +
              "language's English name (e.g. English, Polish, Spanish, German) " +
              "in the 'language' field.",
          },
          { role: "user", content: text },
        ],
        temperature: 0,
        max_tokens: 24,
        response_format: LANG_SCHEMA,
      }),
    });
    if (!res.ok) return null;
    const data = await res.json();
    const content: string | undefined = data?.choices?.[0]?.message?.content;
    if (!content) return null;
    const parsed = JSON.parse(content.replace(/```json|```/g, "").trim());
    const lang = String(parsed?.language ?? "").trim();
    return lang || null;
  } catch {
    return null;
  }
}

export interface LanguageState {
  loading: boolean;
  lang: string | null;
}

/** Detect (and cache) the text's language name via the local LLM. */
export function useLanguage(
  text: string,
  llmUrl: string,
  enabled: boolean,
): LanguageState {
  const [state, setState] = useState<LanguageState>(() =>
    langCache.has(text)
      ? { loading: false, lang: langCache.get(text)! }
      : { loading: true, lang: null },
  );

  useEffect(() => {
    if (!enabled || !text) return;
    if (langCache.has(text)) {
      setState({ loading: false, lang: langCache.get(text)! });
      return;
    }
    let cancelled = false;
    setState({ loading: true, lang: null });
    fetchLanguage(text, llmUrl).then((lang) => {
      if (cancelled) return;
      langCache.set(text, lang);
      setState({ loading: false, lang });
    });
    return () => {
      cancelled = true;
    };
  }, [text, llmUrl, enabled]);

  return state;
}

export interface RewriteState {
  loading: boolean;
  text: string;
  error: boolean;
}

/** Fetch (and cache) one style's rewrite for `text` from the local LLM. */
export function useRewrite(
  style: string,
  text: string,
  llmUrl: string,
  enabled: boolean,
  language: string | null,
  attempt: number,
  target: string,
): RewriteState {
  const key = `${style}|${text}|${attempt}|${target}`;
  const [state, setState] = useState<RewriteState>(() =>
    cache.has(key)
      ? { loading: false, text: cache.get(key)!, error: false }
      : { loading: true, text: "", error: false },
  );

  useEffect(() => {
    if (!enabled || !text) return;
    if (cache.has(key)) {
      setState({ loading: false, text: cache.get(key)!, error: false });
      return;
    }
    let cancelled = false;
    setState({ loading: true, text: "", error: false });
    fetchRewrite(style, text, llmUrl, language, attempt, target).then((result) => {
      if (cancelled) return;
      if (result != null) {
        cache.set(key, result);
        setState({ loading: false, text: result, error: false });
      } else {
        setState({ loading: false, text: "", error: true });
      }
    });
    return () => {
      cancelled = true;
    };
  }, [key, style, text, llmUrl, enabled, language, attempt, target]);

  return state;
}
