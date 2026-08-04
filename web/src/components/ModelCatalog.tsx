import { useEffect, useState } from "react";
import { Check, X } from "lucide-react";
import {
  type DownloadProgress,
  type SettingsState,
  onDownloadProgress,
  send,
} from "@/bridge";
import { Button } from "@/components/ui/button";

// Catalog data comes from the shared model manifest (adapters.ts wraps
// Sources/loco/Resources/models.json — also read by Swift).
import { ADAPTERS, type Capability } from "@/models/adapters";

export type { Capability };

export const CAPABILITY_LABELS: Record<Capability, string> = {
  grammar: "Grammar",
  compose: "Writing",
  translate: "Translation",
};

export const CATALOG = ADAPTERS.map((m) => ({
  id: m.id,
  file: m.file,
  name: m.display.name,
  size: m.display.size,
  note: m.display.note,
  recommended: m.display.recommended,
  caps: m.capabilities,
}));

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
