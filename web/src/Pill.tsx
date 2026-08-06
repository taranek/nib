import { useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import { ThinkingOrb } from "thinking-orbs";
import { type PillStatus, onSetPill } from "./bridge";

/** Margin inside the window, leaving the shadow somewhere to fall. Matches
 *  PillPanel.margin. */
const MARGIN = 4;

/** ThinkingOrb only renders at its two preset sizes (20 or 64), so the small
 *  one is scaled to fit the pill's width rather than sized to it — an
 *  off-preset number renders nothing at all. */
const scaleFor = (windowWidth: number) =>
  Math.min(1, Math.max(0.4, (windowWidth - 2 * MARGIN - 2) / 20));

/** The selection pill as a web surface (hover/click are handled natively by a
 *  tracking view over this webview — this component only renders state).
 *
 *  Sizing is inline rather than utility classes: the shell has to fill a window
 *  that Swift resizes from a 14pt disc to a capsule as tall as the selection,
 *  and percentage sizing inside a 22pt viewport is not the place to find out a
 *  class didn't apply. */
export function Pill() {
  const [status, setStatus] = useState<PillStatus>({ state: "loading" });
  const [scale, setScale] = useState(() => scaleFor(window.innerWidth));

  useEffect(() => {
    onSetPill(setStatus);
    const onResize = () => setScale(scaleFor(window.innerWidth));
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  const shell: React.CSSProperties = {
    boxSizing: "border-box",
    width: "100vw",
    height: "100vh",
    padding: MARGIN,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    background: "transparent",
  };

  if (status.state === "plain") {
    return (
      <div style={shell}>
        <div
          style={{
            width: 18,
            height: 18,
            borderRadius: 999,
            background: "#2885ef",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <RefreshCw className="size-[10px] text-white" strokeWidth={2.5} />
        </div>
      </div>
    );
  }
  return (
    <div style={shell}>
      {/* The window is transparent — the orb needs its own disc or its dots
          drown in whatever app is behind. Dark disc + dark orb, matching the
          cards' always-dark identity regardless of the system scheme. */}
      <div
        style={{
          width: "100%",
          height: "100%",
          borderRadius: 999,
          background: "#191a1b",
          boxShadow:
            "0 1px 4px rgba(0,0,0,0.4), inset 0 0 0 1px rgba(255,255,255,0.2)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <div style={{ transform: `scale(${scale})`, lineHeight: 0 }}>
          <ThinkingOrb
            state="breathing"
            size={20}
            speed={1.3}
            theme="dark"
            aria-label="Nib is checking"
          />
        </div>
      </div>
    </div>
  );
}
