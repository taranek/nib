import { useEffect, useState } from "react";

// The rewrite styles' instructions. The card fetches the local LLM directly
// from the webview, so these are the live prompts (Swift's RewriteStyle copy
// is unused). Compared old-vs-new on the same model before changing them.
// Keep abbreviations, jargon, names, and code intact across every style — e.g.
// don't turn "config" into "configuration" or "repo" into "repository".
const KEEP_TERMS =
  " Keep abbreviations, acronyms, technical terms, names, and code exactly as " +
  "written — never expand or replace them (e.g. keep 'config', 'repo', 'API').";

// How rewrites should sound: like the writer on a good day, not like a company.
// ("Clear, natural prose" alone made the small model reach for formal words —
// "becoming unmanageable", "What is your opinion?", "Apologies for the delay".)
const VOICE =
  " Sound like a person talking to a colleague, not like a company: plain everyday " +
  "words, contractions, short sentences. Match the writer: if they write in lowercase, " +
  "stay lowercase; if they capitalize, capitalize properly. Either way, \"I\" is always " +
  "capitalized, and names, acronyms and labels keep their capitals (API, PR, option A). " +
  "Keep the same level of formality and politeness — don't make it stiffer, and don't " +
  "make it curt (keep a \"please\" or \"could you\" they wrote, keep their greeting). " +
  "No corporate filler (\"I hope this finds you well\", \"please be advised\", " +
  "\"kindly\", \"utilize\", \"reach out\", \"at your earliest convenience\", " +
  "\"I am writing to\"), and don't add greetings, sign-offs, apologies, thanks or " +
  "emoji they didn't write.";

const INSTRUCTIONS: Record<string, string> = {
  grammar:
    "Correct only the spelling, grammar, and punctuation in the user's text, " +
    "changing as little as possible. Keep the original wording, meaning, tone, " +
    "and length. Keep numbers and times exactly as written (3pm stays 3pm). " +
    "If there are no errors, return the text unchanged." +
    KEEP_TERMS +
    " Put the result in the 'rewrite' field.",
  // Understand first, then say it better: the point, the ask, the tone.
  rephrase:
    "You help someone say what they mean in a message they're writing. First work out " +
    "what they're really trying to say: the point, any question or request, and the tone " +
    "they're going for. Then rewrite the message so that point comes across clearly — the " +
    "way they'd say it themselves if they had a minute to think.\n" +
    "- Lead with the point. Cut detours, repetition and filler.\n" +
    "- Every idea in the original must still be there: each fact, name, number, question " +
    "and commitment, and any doubt they expressed (\"not sure\", \"probably\"). Add " +
    "nothing new; where something is ambiguous, keep the most likely meaning instead of " +
    "inventing details. Keep who does what for whom — when you turn a passive sentence " +
    "around, the same person still acts. Keep the words that carry the meaning — don't " +
    "swap a specific term for a vaguer one or drop it.\n" +
    "- Same language as the original, same length or shorter." +
    VOICE +
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

// Worked examples for Rephrase — the small model follows these far better than
// rules (keep the specific term, keep "please", cut officialese). English only:
// in other languages English examples pulled it into English or garbled it.
const REPHRASE_EXAMPLES: [string, string][] = [
  [
    "so yeah the thing is that the cache kinda gets stale after the deploy and idk why",
    "the cache goes stale after the deploy and I don't know why",
  ],
  [
    "Could you please send me the logs from yesterday when you have a moment?",
    "Could you please send me yesterday's logs when you get a chance?",
  ],
  [
    "Hi Mark, I am reaching out in order to ask whether it would be possible to move our sync to Thursday.",
    "Hi Mark, could we move our sync to Thursday?",
  ],
];

// "Try again" rotates through these angles (a small model barely varies on
// temperature alone, so we steer the prompt) — cycled by attempt number.
// None of them pushes towards formal: that was the complaint, not a wish.
const RETRY_NUDGES = [
  " This time: vary the wording.",
  " This time: say it more directly — get to the point faster.",
  " This time: make it a bit warmer and friendlier.",
  " This time: make it shorter.",
  " This time: make it sound more confident — drop hedges that don't carry " +
    "meaning, but keep it polite.",
];

// Rephrase retries start from a looser base: with the first pass's worked
// examples the model anchored to near-copies, so "Try again" barely changed.
const REPHRASE_RETRY =
  "Rewrite the user's message in different words — restructure it rather than " +
  "making small edits — keeping exactly the same meaning, every fact and question, " +
  "and the same language." +
  VOICE +
  KEEP_TERMS +
  " Put the result in the 'rewrite' field.";

// Module-level cache (style|text → result) so re-tabbing / re-mounting is instant.
const cache = new Map<string, string>();

// Per-model output validation (echo markers, growth caps) lives in the model
// adapters — quirks are declared in the manifest, not hardcoded here.
import { isImplausibleOutput } from "@/models/adapters";

/** POST a chat request with per-attempt timeout and retry. Task servers spawn
 *  lazily and take seconds to load a model — during that window requests are
 *  refused or 503'd; retrying keeps the UI in its loading state until the
 *  server is up instead of hanging or failing on the first open. */
async function postChat(
  llmUrl: string,
  body: unknown,
  retries = 10,
): Promise<unknown | null> {
  for (let attempt = 0; attempt < retries; attempt++) {
    try {
      const res = await fetch(llmUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
        // Generous: covers slow generations under GPU contention.
        signal: AbortSignal.timeout(90_000),
      });
      if (res.ok) return await res.json();
      if (res.status !== 503) return null; // real error — don't hammer
    } catch {
      // connection refused / aborted — server likely cold-starting
    }
    await new Promise((r) => setTimeout(r, 2500));
  }
  return null;
}

async function fetchRewrite(
  style: string,
  text: string,
  llmUrl: string,
  language: string | null,
  attempt: number,
  target: string,
  modelFile?: string,
): Promise<string | null> {
  const retry = attempt > 0;
  let instruction =
    style === "rephrase" && retry
      ? REPHRASE_RETRY
      : (INSTRUCTIONS[style] ?? INSTRUCTIONS.grammar);
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
  if (retry) {
    instruction += RETRY_NUDGES[(attempt - 1) % RETRY_NUDGES.length];
  }
  const examples =
    style === "rephrase" && !retry && (!language || language === "English")
      ? REPHRASE_EXAMPLES.flatMap(([u, a]) => [
          { role: "user", content: u },
          { role: "assistant", content: JSON.stringify({ rewrite: a }) },
        ])
      : [];
  try {
    const data = (await postChat(llmUrl, {
      messages: [
        { role: "system", content: instruction },
        ...examples,
        { role: "user", content: text },
      ],
      temperature: retry ? 0.8 : 0,
      ...(retry ? { seed: attempt, top_p: 0.95 } : {}),
      max_tokens: 1024,
      response_format: SCHEMA,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    })) as any;
    if (!data) return null;
    const content: string | undefined = data?.choices?.[0]?.message?.content;
    if (!content) return null;
    const json = content.replace(/```json|```/g, "").trim();
    const parsed = JSON.parse(json);
    const out = (parsed?.rewrite ?? "").trim();
    if (!out || isImplausibleOutput(out, text, modelFile)) return null;
    return out;
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
    "meaning and language unless told otherwise. Unless an instruction asks for " +
    "it, don't make the text more formal or official than the writer's own voice." +
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
    const data = (await postChat(llmUrl, {
      messages,
      temperature: 0.4,
      max_tokens: 1024,
      response_format: SCHEMA,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    })) as any;
    if (!data) return null;
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

// ── Fix explanations ────────────────────────────────────────────────────────
// The changed word pairs are computed client-side (ground truth, from the same
// diff the card displays), then one LLM call explains EVERY change — one entry
// per pair, so multi-fix corrections are fully covered. A second on-demand call
// produces example pairs for one rule.

import { changedPairs } from "@/lib/diff";

/** One explained change: what changed plus the friendly why. */
export interface FixDetail {
  /** The changed run in the original ("" for pure insertions). */
  from: string;
  /** What it became ("" for pure removals). */
  to: string;
  /** Short rule name, e.g. "Sentence capitalization". */
  rule: string;
  /** One friendly sentence on why the fix is right. */
  explanation: string;
}

// Explaining more changes than this clutters the card (and strains the model).
const MAX_EXPLAINED = 4;

// Exactly one {rule, explanation} entry per change, enforced by the schema.
function explainSchema(count: number) {
  return {
    type: "json_schema",
    json_schema: {
      name: "explain",
      strict: true,
      schema: {
        type: "object",
        properties: {
          fixes: {
            type: "array",
            minItems: count,
            maxItems: count,
            items: {
              type: "object",
              properties: {
                rule: { type: "string" },
                explanation: { type: "string" },
              },
              required: ["rule", "explanation"],
            },
          },
        },
        required: ["fixes"],
      },
    },
  };
}

const explainCache = new Map<string, FixDetail[] | null>();

async function fetchFixExplanations(
  original: string,
  corrected: string,
  llmUrl: string,
): Promise<FixDetail[] | null> {
  const pairs = changedPairs(original, corrected).slice(0, MAX_EXPLAINED);
  if (!pairs.length) return null;
  const changeList = pairs
    .map(
      (p, i) =>
        `${i + 1}. "${p.from || "(nothing)"}" → "${p.to || "(removed)"}"`,
    )
    .join("\n");
  try {
    const res = await fetch(llmUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messages: [
          {
            role: "system",
            content:
              "You explain grammar corrections in a friendly, non-technical " +
              "way. The user lists every change made to their sentence. For " +
              "EACH change, in the same order, name the rule behind it in the " +
              "'rule' field (2-5 words, e.g. \"Sentence capitalization\" or " +
              "\"Verb form after 'can'\") and give one plain-language sentence " +
              "(under 18 words) on why the correction is right in the " +
              "'explanation' field. Describe the rule the change actually " +
              "demonstrates — don't generalize beyond it. Answer in the " +
              "sentence's own language.",
          },
          {
            role: "user",
            content:
              `Sentence: ${original}\nCorrected: ${corrected}\n` +
              `Changes:\n${changeList}`,
          },
        ],
        temperature: 0,
        max_tokens: 128 * pairs.length,
        response_format: explainSchema(pairs.length),
      }),
    });
    if (!res.ok) return null;
    const data = await res.json();
    const content: string | undefined = data?.choices?.[0]?.message?.content;
    if (!content) return null;
    const parsed = JSON.parse(content.replace(/```json|```/g, "").trim());
    const list = Array.isArray(parsed?.fixes) ? parsed.fixes : [];
    const fixes: FixDetail[] = pairs.flatMap((p, i) => {
      const rule = String(list[i]?.rule ?? "").trim();
      const explanation = String(list[i]?.explanation ?? "").trim();
      return rule && explanation
        ? [{ from: p.from, to: p.to, rule, explanation }]
        : [];
    });
    return fixes.length ? fixes : null;
  } catch {
    return null;
  }
}

export interface FixExplanationsState {
  loading: boolean;
  fixes: FixDetail[] | null;
}

/** Fetch (and cache) a friendly explanation for every change in a fix. */
export function useFixExplanations(
  original: string,
  corrected: string,
  llmUrl: string,
  enabled: boolean,
): FixExplanationsState {
  const key = `${original}|${corrected}`;
  const [state, setState] = useState<FixExplanationsState>(() =>
    explainCache.has(key)
      ? { loading: false, fixes: explainCache.get(key)! }
      : { loading: true, fixes: null },
  );

  useEffect(() => {
    if (!enabled || !original || !corrected || !llmUrl) return;
    if (explainCache.has(key)) {
      setState({ loading: false, fixes: explainCache.get(key)! });
      return;
    }
    let cancelled = false;
    setState({ loading: true, fixes: null });
    fetchFixExplanations(original, corrected, llmUrl).then((fixes) => {
      if (cancelled) return;
      explainCache.set(key, fixes);
      setState({ loading: false, fixes });
    });
    return () => {
      cancelled = true;
    };
  }, [key, original, corrected, llmUrl, enabled]);

  return state;
}

export interface ExamplePair {
  wrong: string;
  right: string;
}

const EXAMPLES_SCHEMA = {
  type: "json_schema",
  json_schema: {
    name: "examples",
    strict: true,
    schema: {
      type: "object",
      properties: {
        examples: {
          type: "array",
          minItems: 2,
          maxItems: 3,
          items: {
            type: "object",
            properties: {
              wrong: { type: "string" },
              right: { type: "string" },
            },
            required: ["wrong", "right"],
          },
        },
      },
      required: ["examples"],
    },
  },
};

const examplesCache = new Map<string, ExamplePair[] | null>();

/** Fetch (and cache) short wrong → right example pairs illustrating one fix. */
export async function fetchExamples(
  fix: FixDetail,
  llmUrl: string,
): Promise<ExamplePair[] | null> {
  const key = `${fix.rule}|${fix.from}|${fix.to}`;
  if (examplesCache.has(key)) return examplesCache.get(key)!;
  try {
    const res = await fetch(llmUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messages: [
          {
            role: "system",
            content:
              "You teach grammar with tiny examples. Given a rule and the " +
              "user's mistake, write 2 DIFFERENT short sentences that make " +
              "the SAME mistake. In each pair, 'wrong' is the sentence " +
              "CONTAINING the mistake and 'right' is that same sentence " +
              "corrected — never the other way around. Keep each sentence " +
              "under 8 words. Answer in the same language as the mistake.",
          },
          {
            role: "user",
            content:
              `Rule: ${fix.rule} — ${fix.explanation}\n` +
              `The user wrote "${fix.from}" (incorrect); it was corrected to ` +
              `"${fix.to}". So every 'wrong' sentence must use a "${fix.from}"-` +
              `style form, and every 'right' sentence its "${fix.to}"-style fix.`,
          },
        ],
        temperature: 0.3,
        max_tokens: 192,
        response_format: EXAMPLES_SCHEMA,
      }),
    });
    if (!res.ok) return null;
    const data = await res.json();
    const content: string | undefined = data?.choices?.[0]?.message?.content;
    if (!content) return null;
    const parsed = JSON.parse(content.replace(/```json|```/g, "").trim());
    const list = Array.isArray(parsed?.examples) ? parsed.examples : [];
    // Small models sometimes swap the fields. The user's mistake tells us the
    // intended direction — the 'wrong' sentence should carry the `from` form
    // and 'right' the `to` form; flip any pair that has it backwards.
    const has = (s: string, w: string) =>
      !!w && s.toLowerCase().includes(w.toLowerCase());
    const examples: ExamplePair[] = list
      .map((e: { wrong?: unknown; right?: unknown }) => ({
        wrong: String(e?.wrong ?? "").trim(),
        right: String(e?.right ?? "").trim(),
      }))
      .map((e: ExamplePair) =>
        has(e.wrong, fix.to) && has(e.right, fix.from) && !has(e.wrong, fix.from)
          ? { wrong: e.right, right: e.wrong }
          : e,
      )
      .filter((e: ExamplePair) => e.wrong && e.right && e.wrong !== e.right);
    const out = examples.length ? examples : null;
    examplesCache.set(key, out);
    return out;
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
  attempt: number,
  target: string,
  modelFile?: string,
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
    fetchRewrite(style, text, llmUrl, language, attempt, target, modelFile).then((result) => {
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
