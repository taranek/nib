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

// Module-level cache (style|text → result) so re-tabbing / re-mounting is instant.
const cache = new Map<string, string>();

async function fetchRewrite(
  style: string,
  text: string,
  llmUrl: string,
  language: string | null,
): Promise<string | null> {
  let instruction = INSTRUCTIONS[style] ?? INSTRUCTIONS.grammar;
  // Grammar/Rephrase/Shorten respond in the text's own language; reinforce the
  // detected one so a small model doesn't drift to English. (Translate is fixed.)
  if (style !== "translate" && language) {
    instruction += ` The text is written in ${language}; respond in ${language}.`;
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
        temperature: 0,
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
): RewriteState {
  const key = `${style}|${text}`;
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
    fetchRewrite(style, text, llmUrl, language).then((result) => {
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
  }, [key, style, text, llmUrl, enabled, language]);

  return state;
}
