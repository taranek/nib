import * as React from "react";

import { cn } from "@/lib/utils";

/** Shared pill look — the single source of truth for Chip and the static Pill. */
export const chipBase =
  "rounded-full border border-border bg-accent px-[9px] py-0.5 text-[11px] text-subtle";

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
        chipBase,
        "cursor-pointer transition-[background-color,color,border-color] duration-150",
        "focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-ring",
        "disabled:cursor-default disabled:opacity-50",
        active &&
          "border-foreground bg-foreground text-background",
        !active && "enabled:hover:bg-accent-hover enabled:hover:text-foreground",
        className,
      )}
      {...props}
    />
  );
}

export { Chip };
