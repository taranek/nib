import { useEffect, useState } from "react";
import { Check, X } from "lucide-react";
import {
  type DownloadProgress,
  type SettingsState,
  onDownloadProgress,
  send,
} from "@/bridge";
import { Button } from "@/components/ui/button";

// Curated models the user can download from Hugging Face. Keep ids and files in
// sync with modelCatalog in AppController.swift (which holds the download URLs).
const CATALOG = [
  {
    id: "gemma-4-e2b",
    file: "gemma-4-E2B-it-Q4_K_M.gguf",
    name: "Gemma 4 E2B",
    size: "3.1 GB",
    note: "Best quality for writing help",
    recommended: true,
  },
  {
    id: "qwen2.5-3b",
    file: "Qwen2.5-3B-Instruct-Q4_K_M.gguf",
    name: "Qwen 2.5 3B",
    size: "2.1 GB",
    note: "Fast and compact",
    recommended: false,
  },
  {
    id: "llama-3.2-3b",
    file: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
    name: "Llama 3.2 3B",
    size: "2.0 GB",
    note: "Solid all-rounder",
    recommended: false,
  },
];

/** The downloadable-models list shared by onboarding and settings: Get to
 *  download (with progress + cancel), Use to activate an already-downloaded
 *  model, Active for the current one, plus the local-file fallback. */
export function ModelCatalog({ state }: { state: SettingsState }) {
  const [dl, setDl] = useState<DownloadProgress | null>(null);
  useEffect(() => {
    onDownloadProgress(setDl);
  }, []);
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
