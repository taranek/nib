// Model adapters — the TypeScript face of the shared manifest
// (Sources/loco/Resources/models.json, also read by Swift). All per-model
// knowledge lives behind this module: catalog display data, capabilities,
// and output validation quirks. Add a model in the manifest, not in code.

import manifest from "../../../Sources/loco/Resources/models.json";

export type Capability = "grammar" | "compose" | "translate";

export interface ModelAdapter {
  id: string;
  file: string;
  url: string;
  display: {
    name: string;
    size: string;
    note: string;
    recommended: boolean;
  };
  capabilities: Capability[];
  /** ISO codes the model is safe in; absent = no restriction. */
  languages?: string[];
  license: string;
  /** Output-validation quirks (e.g. prompt-echoing fine-tunes). */
  validate?: {
    echoMarkers?: string[];
    maxGrowth?: number;
  };
}

export const ADAPTERS: ModelAdapter[] = manifest.models as ModelAdapter[];

/** Generic markers every model's output is screened for — fragments of our own
 *  prompts that only appear when a model echoes instructions back. */
const GENERIC_ECHO_MARKERS = [
  "Put the result in the",
  "never expand or replace them",
  "'rewrite' field",
  '"rewrite" field',
  "Detect the source language automatically",
];

/** Adapter for a model file; undefined for unknown (user-supplied) models. */
export function adapterFor(file?: string): ModelAdapter | undefined {
  return file ? ADAPTERS.find((m) => m.file === file) : undefined;
}

/** Display name for a model file (catalog name, else file sans extension). */
export function displayName(file: string): string {
  return adapterFor(file)?.display.name ?? file.replace(/\.gguf$/, "");
}

/** Whether a model's output looks like a prompt echo / implausible result
 *  rather than a genuine rewrite. `original` enables growth checks. */
export function isImplausibleOutput(
  out: string,
  original?: string,
  modelFile?: string,
): boolean {
  const adapter = adapterFor(modelFile);
  const markers = [
    ...GENERIC_ECHO_MARKERS,
    ...(adapter?.validate?.echoMarkers ?? []),
  ];
  if (markers.some((m) => out.includes(m))) return true;
  const maxGrowth = adapter?.validate?.maxGrowth;
  if (maxGrowth && original) {
    if (out.length > Math.max(original.length * maxGrowth, original.length + 60)) {
      return true;
    }
  }
  return false;
}
