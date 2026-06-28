import * as React from "react";

import { cn } from "@/lib/utils";

/** Static, non-interactive pill (e.g. the model name). */
function Pill({ className, ...props }: React.ComponentProps<"span">) {
  return (
    <span
      data-slot="pill"
      className={cn(
        "inline-flex max-w-full items-center self-start overflow-hidden text-ellipsis whitespace-nowrap",
        "rounded-full border border-border bg-accent px-[9px] py-0.5 text-[11px] text-subtle",
        className,
      )}
      {...props}
    />
  );
}

export { Pill };
