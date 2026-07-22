import { Power } from "lucide-react";
import { send } from "@/bridge";
import { cn } from "@/lib/utils";

/** Shared card top bar — brand left, quit right — so the onboarding and
 *  settings cards look identical. Dismissing the card is Esc / click-outside;
 *  the header button fully quits the app. `draggable` wires mousedown to a
 *  native window drag (onboarding only; settings stays anchored). */
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
        Nib
      </span>
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
