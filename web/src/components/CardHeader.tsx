import { X } from "lucide-react";
import { send } from "@/bridge";
import { cn } from "@/lib/utils";

/** Shared card top bar — brand left, close right — so the onboarding and
 *  settings cards look identical. `draggable` wires mousedown to a native
 *  window drag (onboarding only; settings stays anchored to the menu bar). */
export function CardHeader({ draggable = false }: { draggable?: boolean }) {
  return (
    <div
      className="relative z-20 flex cursor-default items-center justify-between"
      onMouseDown={
        draggable
          ? (e) => {
              if (!(e.target as HTMLElement).closest("button")) {
                send({ type: "dragWindow" });
              }
            }
          : undefined
      }
    >
      <span
        className={cn(
          "text-[14px] font-semibold tracking-[-0.01em] text-foreground/90",
        )}
      >
        Notavo
      </span>
      <button
        aria-label="Close"
        onClick={() => send({ type: "closeSettings" })}
        className="inline-flex size-7 cursor-pointer items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-white/10 hover:text-foreground"
      >
        <X className="size-4" />
      </button>
    </div>
  );
}
