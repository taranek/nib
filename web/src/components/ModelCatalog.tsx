import { useEffect, useState } from "react";
import { Check, X } from "lucide-react";
import {
  type DownloadProgress,
  type SettingsState,
  onDownloadProgress,
  send,
} from "@/bridge";
import { Button } from "@/components/ui/button";

// What each model can be trusted with (mirrors ModelCapability in Swift).
export type Capability = "grammar" | "compose" | "translate";

export const CAPABILITY_LABELS: Record<Capability, string> = {
  grammar: "Grammar",
  compose: "Writing",
  translate: "Translation",
};

// Curated models the user can download from Hugging Face. Keep ids, files, and
// capabilities in sync with modelCatalog in AppController.swift.
export const CATALOG: {
  id: string;
  file: string;
  name: string;
  size: string;
  note: string;
  recommended: boolean;
  caps: Capability[];
}[] = [
  {
    id: "qwen3-4b",
    file: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
    name: "Qwen3 4B",
    size: "2.4 GB",
    note: "Best all-round, strong in many languages",
    recommended: true,
    caps: ["grammar", "compose", "translate"],
  },
  {
    id: "gemma-4-e2b",
    file: "gemma-4-E2B-it-Q4_K_M.gguf",
    name: "Gemma 4 E2B",
    size: "3.1 GB",
    note: "Best rewrites, fastest",
    recommended: false,
    caps: ["grammar", "compose", "translate"],
  },
  {
    id: "eurollm-9b",
    file: "EuroLLM-9B-Instruct-Q4_K_M.gguf",
    name: "EuroLLM 9B",
    size: "5.2 GB",
    note: "Best translations, 35 languages",
    recommended: false,
    caps: ["grammar", "compose", "translate"],
  },
  {
    id: "grmr-v3-g4b",
    file: "GRMR-V3-G4B-Q8_0.gguf",
    name: "GRMR V3 4B",
    size: "4.1 GB",
    note: "Sharpest grammar fixes · English only",
    recommended: false,
    caps: ["grammar"],
  },
];

/** The downloadable-models list shared by onboarding and settings: Get to
 *  download (with progress + cancel), Use to activate an already-downloaded
 *  model, Active for the current one, plus the local-file fallback. */
export function ModelCatalog({ state }: { state: SettingsState }) {
  const [dl, setDl] = useState<DownloadProgress | null>(null);
  useEffect(
    () =>
      onDownloadProgress((d) => {
        if (d.id !== "app-update") setDl(d);
      }),
    [],
  );
  return (
    <div className="flex flex-col divide-y divide-border/60">
      {CATALOG.map((m) => (
        <ModelRow
          key={m.id}
          m={m}
          state={state}
          dl={dl}
          onCancel={() => {
            send({ type: "cancelDownload" });
            setDl(null);
          }}
        />
      ))}
      <button
        onClick={() => send({ type: "chooseModel" })}
        className="cursor-pointer py-2 text-left text-[11px] text-muted-foreground underline-offset-2 transition-colors hover:text-foreground hover:underline"
      >
        …or choose a local .gguf file
      </button>
    </div>
  );
}

function ModelRow({
  m,
  state,
  dl,
  onCancel,
}: {
  m: (typeof CATALOG)[number];
  state: SettingsState;
  dl: DownloadProgress | null;
  onCancel: () => void;
}) {
  const active = state.model === m.file;
  const downloaded = state.downloadedModels?.includes(m.id) ?? false;
  const mine = dl?.id === m.id;
  const downloading = mine && !dl.error && !dl.done;
  const anyDownloading = !!dl && !dl.error && !dl.done;
  return (
    <div className="flex items-center justify-between gap-3 py-2">
      <div className="flex min-w-0 flex-col gap-0.5">
        <span className="flex items-center gap-1.5 text-[13px] text-foreground">
          {m.name}
          {m.recommended && (
            <span className="rounded-full bg-[#2885ef]/20 px-1.5 py-px text-[10px] font-medium text-[#6eb1f7]">
              Recommended
            </span>
          )}
        </span>
        <span className="text-[11px] text-muted-foreground">
          {m.size} · {m.note}
        </span>
        <span className="mt-0.5 flex items-center gap-1">
          {m.caps.map((c) => (
            <span
              key={c}
              className="rounded-full border border-border px-1.5 py-px text-[9px] text-muted-foreground"
            >
              {CAPABILITY_LABELS[c]}
            </span>
          ))}
        </span>
        {mine && dl.error && (
          <span className="text-[11px] text-diff-del">{dl.error}</span>
        )}
      </div>
      {downloading ? (
        <div className="flex flex-none items-center gap-2">
          <div className="h-1 w-16 overflow-hidden rounded-full bg-white/10">
            <div
              className="h-full rounded-full bg-[#2885ef] transition-[width] duration-300"
              style={{ width: `${Math.round(dl.progress * 100)}%` }}
            />
          </div>
          <span className="w-8 text-right text-[11px] text-muted-foreground tabular-nums">
            {Math.round(dl.progress * 100)}%
          </span>
          <button
            aria-label="Cancel download"
            onClick={onCancel}
            className="inline-flex size-6 cursor-pointer items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-white/10 hover:text-foreground"
          >
            <X className="size-3.5" />
          </button>
        </div>
      ) : active ? (
        <span className="inline-flex flex-none items-center gap-1 text-[12px] text-diff-ins">
          <Check className="size-3.5" strokeWidth={3} />
          Active
        </span>
      ) : (
        <Button
          size="sm"
          variant="default"
          disabled={anyDownloading}
          onClick={() =>
            send(
              downloaded
                ? { type: "selectModel", id: m.id }
                : { type: "downloadModel", id: m.id },
            )
          }
        >
          {downloaded ? "Use" : "Get"}
        </Button>
      )}
    </div>
  );
}
