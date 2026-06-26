import * as React from "react";

import { cn } from "@/lib/utils";

type KbdVariant = "solid" | "outline";

/** A single keyboard key (keycap). */
function Kbd({
  className,
  variant = "solid",
  ...props
}: React.ComponentProps<"kbd"> & { variant?: KbdVariant }) {
  return (
    <kbd
      data-slot="kbd"
      className={cn(
        "text-muted-foreground pointer-events-none inline-flex h-[18px] w-fit min-w-[18px] items-center justify-center gap-1 rounded px-1 font-sans text-[11px] leading-none font-medium select-none [&_svg:not([class*='size-'])]:size-3",
        variant === "outline"
          ? "border-border border bg-black/20"
          : "bg-muted",
        className,
      )}
      {...props}
    />
  );
}

/** A group of keys rendered together (e.g. ⌘ + N). */
function KbdGroup({ className, ...props }: React.ComponentProps<"kbd">) {
  return (
    <kbd
      data-slot="kbd-group"
      className={cn("inline-flex items-center gap-1", className)}
      {...props}
    />
  );
}

export { Kbd, KbdGroup };
