import { useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import { type PillStatus, onSetPill } from "./bridge";

/** The selection pill as a web surface (hover/click are handled natively by a
 *  tracking view over this webview — this component only renders state). A
 *  spinning glass ring invites the user in; it stills once the card is open. */
export function Pill() {
  const [status, setStatus] = useState<PillStatus>({ state: "loading" });

  useEffect(() => {
    onSetPill(setStatus);
  }, []);

  const { state } = status;
  if (state === "plain") {
    return (
      <div className="flex h-screen w-screen items-center justify-center bg-transparent">
        <div className="flex size-[18px] items-center justify-center rounded-full bg-[#2885ef]">
          <RefreshCw className="size-[10px] text-white" strokeWidth={2.5} />
        </div>
      </div>
    );
  }
  return (
    <div className="flex h-screen w-screen items-center justify-center bg-transparent">
      <span
        className="pill-glass-loader"
        style={state === "open" ? { animationPlayState: "paused" } : undefined}
      />
    </div>
  );
}
