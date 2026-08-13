import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { type AlertData, onSetAlert, send } from "./bridge";
import { Button } from "@/components/ui/button";
import { NibGlyph } from "@/components/NibGlyph";

const CARD_SHADOW =
  "shadow-[0_6px_16px_rgba(0,0,0,0.4),0_1px_4px_rgba(0,0,0,0.3),inset_0_1px_0_rgba(255,255,255,0.05)]";

/** Shown under the menu-bar icon when the app you're writing in has a wedged
 *  accessibility server — Nib can't read its text until it restarts. Same dark,
 *  rounded identity as the rewrite card. */
export function Alert() {
  const [data, setData] = useState<AlertData>({ appName: "the app" });
  const wrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    onSetAlert(setData);
    send({ type: "ready" });
  }, []);

  // Report size so the native panel fits the card exactly (matches the pattern
  // used by the card and settings surfaces).
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
      <div
        className={`relative box-border flex w-[300px] flex-col gap-3 overflow-hidden rounded-[12px] border border-border bg-card p-4 text-[13px] text-subtle ${CARD_SHADOW}`}
      >
        <div className="flex items-center gap-2">
          <NibGlyph className="-ml-0.5 size-[22px]" />
          <span className="inline-flex items-center gap-2 text-[14px] font-semibold text-foreground/90">
            Can't read {data.appName}
            <span className="size-2 rounded-full bg-diff-del" aria-hidden />
          </span>
        </div>

        <p className="text-[12px] leading-snug text-muted-foreground">
          {data.appName}'s accessibility stopped responding — this happens after
          your Mac sleeps. Reopen it so Nib can check your writing.
        </p>

        <div className="mt-1 flex items-center justify-end gap-2">
          <Button
            size="sm"
            variant="default"
            onClick={() => send({ type: "dismissAlert" })}
          >
            Later
          </Button>
          <Button
            size="sm"
            variant="brand"
            onClick={() => send({ type: "reopenApp" })}
          >
            Reopen {data.appName}
          </Button>
        </div>
      </div>
    </div>
  );
}
