import * as React from "react";

import { cn } from "@/lib/utils";
import { chipBase } from "./chip";

/** Static, non-interactive pill (e.g. the model name) — same look as Chip. */
function Pill({ className, ...props }: React.ComponentProps<"span">) {
  return (
    <span
      data-slot="pill"
      className={cn(
        chipBase,
        "inline-flex max-w-full items-center self-start overflow-hidden text-ellipsis whitespace-nowrap",
        className,
      )}
      {...props}
    />
  );
}

export { Pill };
