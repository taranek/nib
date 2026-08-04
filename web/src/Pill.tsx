import { useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import { ThinkingOrb } from "thinking-orbs";
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
      {/* The window is transparent — the orb needs its own disc or its dots
          drown in whatever app is behind. Dark disc + dark orb, matching the
          cards' always-dark identity regardless of the system scheme. */}
      <div className="flex size-6 items-center justify-center rounded-full bg-[#191a1b] shadow-[0_1px_4px_rgba(0,0,0,0.4)] ring-1 ring-white/20">
        <ThinkingOrb
          state="breathing"
          size={20}
          speed={1.3}
          theme="dark"
          paused={state === "open"}
          aria-label="Nib is checking"
        />
      </div>
    </div>
  );
}
