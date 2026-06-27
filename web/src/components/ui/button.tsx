import * as React from "react";

import { cn } from "@/lib/utils";

type ButtonVariant = "default" | "brand" | "outline";
type ButtonSize = "sm" | "md";

const VARIANTS: Record<ButtonVariant, string> = {
  // Matches the motion tab pill: raised accent surface + hairline ring. Text is
  // slightly dimmed and brightens to white on hover. Ring is inset so it doesn't
  // add to the button's footprint.
  default:
    "bg-accent text-[var(--text-secondary)] ring-1 ring-inset ring-border hover:bg-[var(--accent-hover)] hover:text-foreground hover:ring-white/20",
  // Brand, but a touch less prominent than full primary (lifts to it on hover).
  brand:
    "group bg-[var(--primary-soft)] text-primary-foreground ring-1 ring-inset ring-white/10 hover:bg-primary hover:text-white",
  // Outline: bordered surface that fills with accent on hover.
  outline:
    "border border-input bg-background text-foreground shadow-sm shadow-black/5 hover:bg-accent hover:text-accent-foreground",
};

const SIZES: Record<ButtonSize, string> = {
  sm: "h-7 rounded-md px-2.5 text-xs",
  md: "h-9 rounded-lg px-4 text-sm",
};

/**
 * Button matching the motion tab pill (default/sm) with brand + outline variants.
 * Composes an optional leading icon and a trailing shortcut, e.g.:
 *   <Button variant="outline" size="md">
 *     <PrinterIcon className="-ms-1 me-2 opacity-60" /> Print
 *     <Kbd className="-me-1 ms-3 border">⌘P</Kbd>
 *   </Button>
 */
function Button({
  className,
  variant = "default",
  size = "sm",
  ...props
}: React.ComponentProps<"button"> & {
  variant?: ButtonVariant;
  size?: ButtonSize;
}) {
  return (
    <button
      data-slot="button"
      className={cn(
        "inline-flex cursor-pointer items-center justify-center gap-1.5 font-medium whitespace-nowrap select-none",
        "transition-[background-color,box-shadow,transform,color] outline-none",
        "active:scale-[0.96] focus-visible:ring-2 focus-visible:ring-ring",
        "disabled:pointer-events-none disabled:opacity-50",
        "[&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        SIZES[size],
        VARIANTS[variant],
        className,
      )}
      {...props}
    />
  );
}

export { Button };
