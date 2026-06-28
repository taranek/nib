import * as React from "react";

import { cn } from "@/lib/utils";

/** Square, neutral icon button (composer send, header retry). */
function IconButton({ className, ...props }: React.ComponentProps<"button">) {
  return (
    <button
      data-slot="icon-button"
      className={cn(
        "inline-flex size-7 flex-none cursor-pointer items-center justify-center rounded-md",
        "bg-accent text-[var(--text-secondary)] transition-[background-color,color] duration-150",
        "enabled:hover:bg-[var(--accent-hover)] enabled:hover:text-foreground",
        "disabled:cursor-default disabled:opacity-40",
        "[&_svg]:pointer-events-none [&_svg]:shrink-0",
        className,
      )}
      {...props}
    />
  );
}

export { IconButton };
