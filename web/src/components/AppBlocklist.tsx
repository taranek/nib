import { useEffect, useMemo, useState } from "react";
import { Search } from "lucide-react";
import { type AppInfo, onSetApps, send } from "@/bridge";
import { Toggle } from "@/components/ui/toggle";

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

  useEffect(() => {
    onSetApps(setApps);
    send({ type: "listApps" });
  }, []);

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
      <div className="flex flex-col gap-2.5 border-t border-border pt-3.5">
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

      <div className="thin-scroll-xs -mr-4 flex max-h-[420px] flex-col gap-1 overflow-y-auto overscroll-contain pr-4">
        {apps === null ? (
          <span className="py-3 text-[13px] text-muted-foreground">
            Looking for installed apps…
          </span>
        ) : shown.length === 0 ? (
          <span className="py-3 text-[13px] text-muted-foreground">
            No app matches “{query}”.
          </span>
        ) : (
          shown.map((app) => (
            <div key={app.id} className="flex items-center gap-2.5 py-1">
              {app.icon ? (
                <img src={app.icon} alt="" className="size-5 shrink-0" />
              ) : (
                <span className="size-5 shrink-0 rounded bg-white/5" />
              )}
              <span className="min-w-0 flex-1 truncate text-[13px] text-foreground">
                {app.name}
              </span>
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
            </div>
          ))
        )}
      </div>
    </>
  );
}
