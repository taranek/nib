import * as React from "react";

import { cn } from "@/lib/utils";

/** Quick-filter chip. `active` inverts it (filled) and drops the hover change. */
function Chip({
  className,
  active = false,
  ...props
}: React.ComponentProps<"button"> & { active?: boolean }) {
  return (
    <button
      data-slot="chip"
      className={cn(
        "cursor-pointer rounded-full border px-[9px] py-0.5 text-[11px]",
        "transition-[background-color,color,border-color] duration-150",
        "focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-ring",
        "disabled:cursor-default disabled:opacity-50",
        active
          ? "border-foreground bg-foreground text-background"
          : "border-border bg-accent text-[var(--text-secondary)] enabled:hover:bg-[var(--accent-hover)] enabled:hover:text-foreground",
        className,
      )}
      {...props}
    />
  );
}

export { Chip };
