import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import { ChevronLeft, ChevronRight, Power } from "lucide-react";
import { NibGlyph } from "@/components/NibGlyph";
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
/** One header for both settings screens: the Nib mark shrinks a little and a
 *  back arrow slides in on the Apps screen, and the title cross-fades. Persists
 *  across the route change so these animate instead of re-mounting. */
function SettingsHeader({
  route,
  onBack,
}: {
  route: Route;
  onBack: () => void;
}) {
  const onApps = route !== "main";   // any sub-page: logo out, back arrow in
  const spring = { type: "spring", stiffness: 500, damping: 34 } as const;
  return (
    <div className="relative z-20 flex items-center justify-between">
      <div className="flex items-center">
        <AnimatePresence initial={false}>
          {onApps && (
            <motion.button
              key="back"
              aria-label="Back to settings"
              onClick={onBack}
              initial={{ width: 0, marginRight: 0, opacity: 0, filter: "blur(4px)" }}
              animate={{ width: 28, marginRight: 6, opacity: 1, filter: "blur(0px)" }}
              exit={{ width: 0, marginRight: 0, opacity: 0, filter: "blur(4px)" }}
              transition={spring}
              className="inline-flex size-7 shrink-0 cursor-pointer items-center justify-center overflow-hidden rounded-md text-muted-foreground transition-colors hover:bg-white/5 hover:text-foreground"
            >
              <ChevronLeft className="size-4" />
            </motion.button>
          )}
        </AnimatePresence>
        <AnimatePresence initial={false}>
          {!onApps && (
            <motion.div
              key="logo"
              initial={{ width: 0, marginRight: 0, opacity: 0, scale: 0.6, filter: "blur(4px)" }}
              animate={{ width: 25, marginRight: 6, opacity: 1, scale: 1, filter: "blur(0px)" }}
              exit={{ width: 0, marginRight: 0, opacity: 0, scale: 0.6, filter: "blur(4px)" }}
              transition={spring}
              className="origin-left overflow-hidden"
            >
              <NibGlyph className="-ml-0.5 size-[25px]" />
            </motion.div>
          )}
        </AnimatePresence>
        <motion.div layout className="relative -mt-[3px] h-[18px] overflow-hidden">
          <AnimatePresence mode="wait" initial={false}>
            <motion.span
              key={route}
              initial={{ opacity: 0, y: 6, filter: "blur(4px)" }}
              animate={{ opacity: 1, y: 0, filter: "blur(0px)" }}
              exit={{ opacity: 0, y: -6, filter: "blur(4px)" }}
              transition={{ duration: 0.18 }}
              className="block text-[14px] font-semibold tracking-[-0.01em] text-foreground/90"
            >
              {ROUTE_TITLE[route]}
            </motion.span>
          </AnimatePresence>
        </motion.div>
      </div>
      <button
        aria-label="Quit Nib"
        title="Quit Nib"
        onClick={() => send({ type: "quit" })}
        className="inline-flex size-7 cursor-pointer items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-diff-del/10 hover:text-diff-del"
      >
        <Power className="size-4" />
      </button>
    </div>
  );
}

type Route = "main" | "popover" | "models" | "apps";

/** A row on the main settings menu that opens a sub-page. Whole row is the hit
 *  target; a chevron on the right nudges and brightens on hover. */
function NavRow({
  title,
  subtitle,
  onClick,
  status,
}: {
  title: string;
  subtitle: string;
  onClick: () => void;
  status?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      className="group flex w-full cursor-pointer items-center justify-between gap-3 border-t border-border py-3.5 text-left"
    >
      <span className="flex min-w-0 flex-col gap-0.5 transition-transform duration-200 ease-out group-hover:translate-x-1 group-hover:delay-75">
        <span className={LABEL}>
          {status !== undefined && <StatusDot ok={status} />}
          {title}
        </span>
        <span className={HINT}>{subtitle}</span>
      </span>
      <span className="mr-1 flex items-center gap-1.5">
        <span className="translate-x-3 text-[12px] font-medium text-muted-foreground opacity-0 transition-all duration-200 ease-out group-hover:translate-x-0 group-hover:text-foreground group-hover:opacity-100 group-hover:delay-75">
          Open
        </span>
        <ChevronRight className="size-4 shrink-0 text-muted-foreground transition-all duration-150 ease-out group-hover:text-foreground group-hover:delay-75" />
      </span>
    </button>
  );
}
const ROUTE_TITLE: Record<Route, string> = {
  main: "Nib",
  popover: "Popover",
  models: "Models",
  apps: "Apps",
};
const ROUTE_SLIDE = {
  enter: (d: number) => ({ x: d > 0 ? 22 : -22, opacity: 0, filter: "blur(5px)" }),
  center: { x: 0, opacity: 1, filter: "blur(0px)" },
  exit: (d: number) => ({ x: d > 0 ? -22 : 22, opacity: 0, filter: "blur(5px)" }),
};
const KEYCAP =
  "inline-flex h-[16px] min-w-[16px] items-center justify-center rounded border border-border bg-white/[0.06] px-1 text-[10.5px] font-medium text-foreground/80 shadow-[0_1px_1px_rgba(0,0,0,0.35),inset_0_1px_0_rgba(255,255,255,0.08)]";
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
    hotkey: "⌘`",
  });

  // Shortcut recorder: while true, the next key combo rebinds the open shortcut.
  const [recording, setRecording] = useState(false);
  useEffect(() => {
    if (!recording) return;
    // Free the global hotkey while recording, or pressing the current combo
    // triggers the card at the OS level instead of reaching this recorder.
    send({ type: "beginHotkeyRecording" });
    const onKey = (e: KeyboardEvent) => {
      e.preventDefault();
      if (e.key === "Escape") {
        setRecording(false);
        return;
      }
      // Ignore a lone modifier press — wait for the actual key.
      if (["Meta", "Shift", "Alt", "Control"].includes(e.key)) return;
      if (!(e.metaKey || e.ctrlKey || e.altKey)) return; // need a modifier
      send({
        type: "setHotkey",
        code: e.code,
        cmd: e.metaKey,
        shift: e.shiftKey,
        option: e.altKey,
        control: e.ctrlKey,
      });
      setRecording(false);
    };
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("keydown", onKey, true);
      send({ type: "endHotkeyRecording" });
    };
  }, [recording]);

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
  const [route, setRoute] = useState<Route>("main");
  // +1 forward (into a sub-page), -1 back — drives the slide direction.
  const [dir, setDir] = useState(1);
  const goTo = (r: Route) => { setDir(1); setRoute(r); };
  const goMain = () => { setDir(-1); setRoute("main"); };
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
          <SettingsHeader route={route} onBack={goMain} />
          <AnimatePresence mode="wait" initial={false} custom={dir}>
          <motion.div
            key={route}
            custom={dir}
            variants={ROUTE_SLIDE}
            initial="enter"
            animate="center"
            exit="exit"
            transition={{ duration: 0.2, ease: [0.32, 0.72, 0, 1] }}
            className="flex flex-col gap-3.5"
          >
          {route === "apps" ? (
            <AppBlocklist
              blocked={state.blockedApps}
              current={state.currentApp}
            />
          ) : route === "popover" ? (
            <>
          {/* The sections scroll; the header stays put. A pixel cap, not a vh
              one — the window is sized to this content, so a viewport-relative
              height would chase itself. */}
          <div className="thin-scroll -mr-4 flex max-h-[520px] flex-col gap-3.5 overflow-y-auto overscroll-contain pr-4">

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
                <span className={LABEL}>Open shortcut</span>
                <span className={HINT}>
                  Opens the rewrite card. Currently{" "}
                  {recording ? (
                    <em className="text-foreground/80 not-italic">press keys…</em>
                  ) : (
                    <span className="inline-flex items-center gap-1 align-middle">
                      {[...state.hotkey].map((k, i) => (
                        <span key={i} className="inline-flex items-center gap-1">
                          {i > 0 && (
                            <span className="text-muted-foreground/60">+</span>
                          )}
                          <kbd className={KEYCAP}>{k}</kbd>
                        </span>
                      ))}
                    </span>
                  )}
                </span>
              </div>
              <Button
                size="sm"
                variant={recording ? "brand" : "default"}
                onClick={() => setRecording((r) => !r)}
              >
                {recording ? "Cancel" : "Change"}
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
          </div>
            </>
          ) : route === "models" ? (
            <>
          {/* The sections scroll; the header stays put. A pixel cap, not a vh
              one — the window is sized to this content, so a viewport-relative
              height would chase itself. */}
          <div className="thin-scroll -mr-4 flex max-h-[520px] flex-col gap-3.5 overflow-y-auto overscroll-contain pr-4">

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
          </div>
            </>
          ) : (
            <>
          {/* The sections scroll; the header stays put. A pixel cap, not a vh
              one — the window is sized to this content, so a viewport-relative
              height would chase itself. */}
          <div className="thin-scroll -mr-4 flex max-h-[520px] flex-col gap-3.5 overflow-y-auto overscroll-contain pr-4">

          <div className="-mb-3.5 flex flex-col">
                    <NavRow
                title="Popover"
                subtitle="Suggestions, shortcut, and translation."
                onClick={() => goTo("popover")}
              />
          <NavRow
                title="Models"
                subtitle="Local model and per-task assignments."
                onClick={() => goTo("models")}
                status={llmReady}
              />
          <NavRow
                title="Apps"
                subtitle="Turn Nib off in specific apps."
                onClick={() => goTo("apps")}
              />
          </div>
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
          </motion.div>
          </AnimatePresence>
        </div>
      )}
    </div>
  );
}
