import { useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  type DownloadProgress,
  type SettingsState,
  type UpdateStatus,
  onDownloadProgress,
  onSetSettings,
  onUpdateStatus,
  send,
} from "./bridge";
import { Button } from "@/components/ui/button";
import { Select } from "@/components/ui/select";
import { Toggle } from "@/components/ui/toggle";
import { Pill } from "@/components/ui/pill";
import { StatusDot } from "@/components/ui/status-dot";
import { Onboarding } from "@/components/Onboarding";
import {
  CATALOG,
  CAPABILITY_LABELS,
  ModelCatalog,
  type Capability,
} from "@/components/ModelCatalog";
import { CardHeader } from "@/components/CardHeader";
import { AppBlocklist } from "@/components/AppBlocklist";

const LANGUAGES = [
  "English",
  "Spanish",
  "German",
  "French",
  "Italian",
  "Portuguese",
  "Dutch",
  "Polish",
  "Japanese",
  "Chinese",
];

const inWebView = Boolean(window.webkit?.messageHandlers?.loco);

/** Simple semver "is `latest` newer than `current`" (dev builds never update). */
function isNewer(latest: string, current: string): boolean {
  if (current === "dev") return false;
  const a = latest.split(".").map(Number);
  const b = current.split(".").map(Number);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if ((a[i] ?? 0) > (b[i] ?? 0)) return true;
    if ((a[i] ?? 0) < (b[i] ?? 0)) return false;
  }
  return false;
}

const SECTION = "flex flex-col gap-2.5 border-t border-border pt-3.5";
const ROW = "flex items-center justify-between gap-3";
const FIELD = "flex min-w-0 flex-col gap-0.5";
const LABEL = "inline-flex items-center gap-[7px] text-[14px] text-foreground";
const HINT = "text-[12px] text-muted-foreground [overflow-wrap:anywhere]";
const CARD_SHADOW =
  "shadow-[0_6px_16px_rgba(0,0,0,0.4),0_1px_4px_rgba(0,0,0,0.3),inset_0_1px_0_rgba(255,255,255,0.05)]";

export function Settings() {
  const [state, setState] = useState<SettingsState>({
    enabled: true,
    accessibilityTrusted: inWebView ? false : true,
    llmStatus: inWebView ? "Loading model…" : "Ready",
    // In `npm run dev` (browser, not the app) start not-ready so the onboarding
    // is previewable; a real run gets state pushed from Swift immediately.
    model: inWebView || import.meta.env.DEV ? "—" : "gemma-4-E2B-it-Q4_K_M.gguf",
    targetLanguage: "English",
    // Start in onboarding; Swift pushes the real flag immediately (and a plain
    // browser / `npm run dev` stays here so the flow is previewable).
    onboardingCompleted: false,
    explainFixes: true,
    blockedApps: [],
    downloadedModels: [],
    customModels: [],
    version: "dev",
    taskModels: { grammar: "default", compose: "default", translate: "default" },
  });

  // Update check: null until checked; Swift reports back via updateStatus.
  const [update, setUpdate] = useState<UpdateStatus | null>(null);
  const [checking, setChecking] = useState(false);
  useEffect(() => {
    onUpdateStatus((s) => {
      setChecking(false);
      setUpdate(s);
    });
  }, []);
  const updateAvailable = !!update?.latest && isNewer(update.latest, state.version);

  // In-place update install: Swift streams progress on the "app-update" id,
  // then the app swaps its bundle and relaunches itself.
  const [updating, setUpdating] = useState<DownloadProgress | null>(null);
  useEffect(
    () =>
      onDownloadProgress((d) => {
        if (d.id === "app-update") setUpdating(d);
      }),
    [],
  );

  const llmReady = state.llmStatus.toLowerCase() === "ready";
  const wrapRef = useRef<HTMLDivElement>(null);
  // "Change" expands the shared model catalog under the Local AI section.
  const [browsingModels, setBrowsingModels] = useState(false);
  // Settings is one card with two screens; "apps" replaces the main one.
  const [route, setRoute] = useState<"main" | "apps">("main");
  // A new model arrived (download, Use, or picker) — collapse the catalog.
  useEffect(() => {
    setBrowsingModels(false);
  }, [state.model]);

  useEffect(() => {
    onSetSettings(setState);
    send({ type: "ready" });
  }, []);

  // Esc closes the settings / onboarding card.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        send({ type: "closeSettings" });
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // Report the card size so the native panel fits it exactly.
  useLayoutEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const report = () =>
      send({
        type: "resize",
        width: Math.ceil(el.offsetWidth),
        height: Math.ceil(el.offsetHeight),
      });
    report();
    const ro = new ResizeObserver(report);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  return (
    <div className="w-max p-6" ref={wrapRef}>
      {!state.onboardingCompleted ? (
        <Onboarding state={state} />
      ) : (
        <div
          className={`relative box-border flex w-[380px] flex-col gap-3.5 overflow-hidden rounded-[12px] border border-border bg-card p-4 text-[13px] text-subtle ${CARD_SHADOW}`}
        >
          {route === "apps" ? (
            <AppBlocklist
              blocked={state.blockedApps}
              current={state.currentApp}
              onBack={() => setRoute("main")}
            />
          ) : (
            <>
          {/* Same top bar as onboarding (not draggable — settings stays
              anchored under the menu-bar icon). */}
          <CardHeader />

          {/* The sections scroll; the header stays put. A pixel cap, not a vh
              one — the window is sized to this content, so a viewport-relative
              height would chase itself. */}
          <div className="flex max-h-[520px] flex-col gap-3.5 overflow-y-auto overscroll-contain pr-1">

          <section className={SECTION}>
            <div className={ROW}>
              <div className={FIELD}>
                <span className={LABEL}>Suggestions</span>
                <span className={HINT}>Grammar and rewrites as you type.</span>
              </div>
              <Toggle
                checked={state.enabled}
                onCheckedChange={(value) => {
                  setState((s) => ({ ...s, enabled: value }));
                  send({ type: "setEnabled", value });
                }}
              />
            </div>
          </section>

          <section className={SECTION}>
            <div className={ROW}>
              <div className={FIELD}>
                <span className={LABEL}>Explain fixes</span>
                <span className={HINT}>
                  Show the grammar rule behind each fix, with examples.
                </span>
              </div>
              <Toggle
                checked={state.explainFixes}
                onCheckedChange={(value) => {
                  setState((s) => ({ ...s, explainFixes: value }));
                  send({ type: "setExplainFixes", value });
                }}
              />
            </div>
          </section>

          <section className={SECTION}>
            <div className={ROW}>
              <div className={FIELD}>
                <span className={LABEL}>Apps</span>
                <span className={HINT}>
                  {state.blockedApps.length === 0
                    ? "Nib works everywhere. Turn it off per app here."
                    : `Off in ${state.blockedApps
                        .map((a) => a.name)
                        .join(", ")}.`}
                </span>
              </div>
              <Button size="sm" variant="default" onClick={() => setRoute("apps")}>
                Manage
              </Button>
            </div>
          </section>

          <section className={SECTION}>
            <div className={ROW}>
              <div className={FIELD}>
                <span className={LABEL}>Translate to</span>
                <span className={HINT}>Language for translations.</span>
              </div>
              <Select
                value={state.targetLanguage}
                options={LANGUAGES}
                onValueChange={(value) => {
                  setState((s) => ({ ...s, targetLanguage: value }));
                  send({ type: "setTargetLanguage", value });
                }}
              />
            </div>
          </section>

          <section className={SECTION}>
            <div className={ROW}>
              <div className={FIELD}>
                <span className={LABEL}>
                  <StatusDot ok={llmReady} />
                  Local AI
                </span>
                <Pill title={state.model}>
                  {llmReady ? state.model : state.llmStatus}
                </Pill>
              </div>
              <Button
                size="sm"
                variant="default"
                onClick={() => setBrowsingModels((b) => !b)}
              >
                {browsingModels ? "Close" : "Change"}
              </Button>
            </div>
            {browsingModels && <ModelCatalog state={state} />}
          </section>

          <section className={SECTION}>
            <div className={FIELD}>
              <span className={LABEL}>Models by task</span>
              <span className={HINT}>
                Use a different downloaded model per task, including{" "}
                <button
                  onClick={() => send({ type: "openModelsFolder" })}
                  className="cursor-pointer underline underline-offset-2 transition-colors hover:text-foreground"
                >
                  your own .gguf files
                </button>
                .
              </span>
            </div>
            {(["grammar", "compose", "translate"] as const).map((task) => {
              // Downloaded catalog models that support the task, plus any
              // user-supplied .gguf (assumed fully capable).
              const eligible = CATALOG.filter(
                (m) =>
                  m.caps.includes(task as Capability) &&
                  state.downloadedModels.includes(m.id),
              );
              const pinned = state.taskModels[task];
              const currentName = pinned.startsWith("file:")
                ? pinned.slice(5).replace(/\.gguf$/, "")
                : (CATALOG.find((m) => m.id === pinned)?.name ?? "Default");
              return (
                <div key={task} className={ROW}>
                  <span className="text-[13px] text-subtle">
                    {CAPABILITY_LABELS[task]}
                  </span>
                  <Select
                    value={currentName}
                    options={[
                      {
                        value: "Default",
                        description: `Active model (${state.model})`,
                      },
                      ...eligible.map((m) => ({
                        value: m.name,
                        description: m.note,
                      })),
                      ...state.customModels.map((f) => ({
                        value: f.replace(/\.gguf$/, ""),
                        description: "Your model",
                      })),
                    ]}
                    onValueChange={(name) => {
                      const custom = state.customModels.find(
                        (f) => f.replace(/\.gguf$/, "") === name,
                      );
                      const id = custom
                        ? `file:${custom}`
                        : (CATALOG.find((m) => m.name === name)?.id ??
                          "default");
                      setState((s) => ({
                        ...s,
                        taskModels: { ...s.taskModels, [task]: id },
                      }));
                      send({ type: "setTaskModel", task, id });
                    }}
                  />
                </div>
              );
            })}
          </section>

          <section className={SECTION}>
            <div className={ROW}>
              <div className={FIELD}>
                <span className={LABEL}>
                  <StatusDot ok={state.accessibilityTrusted} />
                  Accessibility
                </span>
                <span className={HINT}>Access granted.</span>
              </div>
              <Button
                size="sm"
                variant="default"
                onClick={() => send({ type: "openAccessibility" })}
              >
                Open
              </Button>
            </div>
          </section>

          <section className={SECTION}>
            <div className={ROW}>
              <div className={FIELD}>
                <span className={LABEL}>Updates</span>
                <span className={HINT}>
                  {updating && !updating.error
                    ? updating.done
                      ? "Restarting…"
                      : `Downloading update… ${Math.round(updating.progress * 100)}%`
                    : updating?.error
                      ? `Update failed: ${updating.error}`
                      : checking
                        ? "Checking…"
                        : update
                          ? update.latest
                            ? updateAvailable
                              ? `Version ${update.latest} is available.`
                              : "You're up to date."
                            : "Couldn't reach GitHub."
                          : `Version ${state.version}`}
                </span>
              </div>
              {updateAvailable && update ? (
                <Button
                  size="sm"
                  variant="brand"
                  disabled={!!updating && !updating.error}
                  onClick={() =>
                    send({
                      type: "installUpdate",
                      version: update.latest!,
                      url: update.url,
                    })
                  }
                >
                  Update
                </Button>
              ) : (
                <Button
                  size="sm"
                  variant="default"
                  disabled={checking}
                  onClick={() => {
                    setChecking(true);
                    send({ type: "checkForUpdates" });
                  }}
                >
                  Check
                </Button>
              )}
            </div>
          </section>

          <section className={SECTION}>
            <div className={ROW}>
              <div className={FIELD}>
                <span className={LABEL}>Logs</span>
                <span className={HINT}>For troubleshooting.</span>
              </div>
              <Button
                size="sm"
                variant="default"
                onClick={() => send({ type: "openLogs" })}
              >
                Open
              </Button>
            </div>
          </section>
          </div>
            </>
          )}
        </div>
      )}
    </div>
  );
}
