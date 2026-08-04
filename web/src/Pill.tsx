import { useEffect, useState } from "react";
import { Check, RefreshCw } from "lucide-react";
import { type PillStatus, onSetPill } from "./bridge";
import { cn } from "@/lib/utils";

/** The selection pill as a web surface (hover/click are handled natively by a
 *  tracking view over this webview — this component only renders state). */
export function Pill() {
  const [status, setStatus] = useState<PillStatus>({ state: "plain", count: 0 });

  useEffect(() => {
    onSetPill(setStatus);
  }, []);

  const { state, count } = status;
  return (
    <div className="flex h-screen w-screen items-center justify-center bg-transparent">
      <div
        className={cn(
          "flex size-[18px] items-center justify-center rounded-full",
          "transition-colors duration-200",
          state === "checking" && "bg-white ring-1 ring-black/15",
          state === "clean" && "bg-[#40b04f]",
          state === "issues" && "bg-[#e0a64a]",
          state === "plain" && "bg-[#2885ef]",
        )}
      >
        {state === "checking" && (
          <span className="size-[7px] animate-pill-breathe rounded-full bg-black" />
        )}
        {state === "clean" && (
          <Check className="size-[10px] text-white" strokeWidth={3.5} />
        )}
        {state === "issues" && (
          <span className="text-[10px] leading-none font-bold text-white tabular-nums">
            {count > 9 ? "9+" : count}
          </span>
        )}
        {state === "plain" && (
          <RefreshCw className="size-[10px] text-white" strokeWidth={2.5} />
        )}
      </div>
    </div>
  );
}
