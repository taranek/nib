import { useEffect, useMemo, useRef, useState } from "react";
import { motion } from "motion/react";
import { Search } from "lucide-react";
import { type AppInfo, onSetApps, send } from "@/bridge";
import { Toggle } from "@/components/ui/toggle";

// The entrance stagger is a first-impression, not a per-visit effect. This
// survives route navigation (the settings surface stays loaded), so the list
// cascades in once and then just appears on every later visit.
let hasStaggeredOnce = false;

/** Pulsing stand-in rows shown while the app list is still being gathered, so
 *  the panel has its shape immediately instead of a bare line of text. */
function SkeletonRow({ width }: { width: string }) {
  return (
    <div className="flex items-center gap-2.5 py-1 pl-2 pr-1">
      <span className="size-5 shrink-0 animate-pulse rounded bg-white/5" />
      <span
        className="h-3 animate-pulse rounded bg-white/5"
        style={{ width }}
      />
      <span className="ml-auto h-4 w-8 shrink-0 animate-pulse rounded-full bg-white/5" />
    </div>
  );
}

// Varied widths so the placeholder reads as a list of names, not a grid.
const SKELETON_WIDTHS = ["52%", "38%", "64%", "44%", "58%", "34%", "48%", "60%"];

/** The per-app on/off screen: every installed app with a switch. Off means Nib
 *  stays quiet there — no squiggles, no pill. Reached from Settings and shown in
 *  its place, so the card keeps its size and position. */
export function AppBlocklist({
  blocked,
  current,
}: {
  blocked: { id: string; name: string }[];
  current?: { id: string; name: string };
}) {
  const [apps, setApps] = useState<AppInfo[] | null>(null);
  const [query, setQuery] = useState("");
  // Whether *this* mount should play the entrance stagger — captured once, so a
  // re-render (toggling a switch) never replays it, and neither does a return
  // visit once it's been seen.
  const animateIn = useRef(!hasStaggeredOnce);

  useEffect(() => {
    onSetApps(setApps);
    send({ type: "listApps" });
  }, []);

  // Mark the stagger spent once the real list has shown at least once.
  useEffect(() => {
    if (apps && apps.length > 0 && animateIn.current) hasStaggeredOnce = true;
  }, [apps]);

  const blockedIDs = useMemo(() => new Set(blocked.map((b) => b.id)), [blocked]);

  // Apps Nib is off in stay listed even when they don't match the search, so a
  // switch can always be found again.
  const shown = useMemo(() => {
    if (!apps) return [];
    const q = query.trim().toLowerCase();
    if (!q) return apps;
    return apps.filter(
      (a) => a.name.toLowerCase().includes(q) || blockedIDs.has(a.id),
    );
  }, [apps, query, blockedIDs]);

  return (
    <>
      {/* pr-1 mirrors the scrollbar gutter the list below loses on its right,
          so the header's toggles line up with the rows' toggles. */}
      <div className="flex flex-col gap-2.5 border-t border-border pt-3.5 pr-1">
        <span className="text-[12px] text-muted-foreground">
          Turn an app off and Nib stays quiet there.
        </span>
        {current && (
          <div className="flex items-center gap-2.5 rounded-md bg-white/[0.03] px-2 py-1.5">
            {apps?.find((a) => a.id === current.id)?.icon ? (
              <img
                src={apps?.find((a) => a.id === current.id)?.icon}
                alt=""
                className="size-5 shrink-0"
              />
            ) : (
              <span className="size-5 shrink-0 rounded bg-white/5" />
            )}
            <div className="flex min-w-0 flex-1 flex-col">
              <span className="truncate text-[13px] text-foreground">
                {current.name}
              </span>
              <span className="text-[11px] text-muted-foreground">
                The app you were just in
              </span>
            </div>
            <Toggle
              size="sm"
              checked={!blockedIDs.has(current.id)}
              onCheckedChange={(on) =>
                send({
                  type: "setAppBlocked",
                  id: current.id,
                  name: current.name,
                  blocked: !on,
                })
              }
            />
          </div>
        )}
        <div className="flex items-center gap-2 rounded-md border border-border px-2 py-1.5">
          <Search className="size-3.5 shrink-0 text-muted-foreground" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search apps"
            className="min-w-0 flex-1 border-none bg-transparent p-0 text-[13px] text-foreground outline-none placeholder:text-muted-foreground"
          />
        </div>
      </div>

      <div
        className="scroll-mask-y thin-scroll-xs -mr-4 flex max-h-[420px] flex-col gap-1 overflow-y-auto overscroll-contain pr-3"
      >
        {apps === null ? (
          SKELETON_WIDTHS.map((w, i) => <SkeletonRow key={i} width={w} />)
        ) : shown.length === 0 ? (
          <span className="py-3 text-[13px] text-muted-foreground">
            No app matches “{query}”.
          </span>
        ) : (
          shown.map((app, i) => (
            <motion.div
              key={app.id}
              initial={animateIn.current ? { opacity: 0, y: 4 } : false}
              animate={{ opacity: 1, y: 0 }}
              transition={{
                duration: 0.18,
                ease: "easeOut",
                // Only stagger the first screenful; a search re-filter shouldn't
                // ripple through a long list.
                delay: query ? 0 : Math.min(i * 0.022, 0.35),
              }}
              onClick={() =>
                send({
                  type: "setAppBlocked",
                  id: app.id,
                  name: app.name,
                  blocked: !blockedIDs.has(app.id),
                })
              }
              className="flex cursor-pointer items-center gap-2.5 rounded-md py-1 pl-2 pr-1 transition-colors hover:bg-white/[0.03]"
            >
              {app.icon ? (
                <img src={app.icon} alt="" className="size-5 shrink-0" />
              ) : (
                <span className="size-5 shrink-0 rounded bg-white/5" />
              )}
              <span className="min-w-0 flex-1 truncate text-[13px] text-foreground">
                {app.name}
              </span>
              {/* The switch shares the row's handler; stop the click here so a
                  direct hit doesn't also bubble to the row and cancel itself. */}
              <span
                className="flex items-center self-center"
                onClick={(e) => e.stopPropagation()}
              >
                <Toggle
                  size="sm"
                  checked={!blockedIDs.has(app.id)}
                  onCheckedChange={(on) =>
                    send({
                      type: "setAppBlocked",
                      id: app.id,
                      name: app.name,
                      blocked: !on,
                    })
                  }
                />
              </span>
            </motion.div>
          ))
        )}
      </div>
    </>
  );
}
