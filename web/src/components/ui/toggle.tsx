import { cn } from "@/lib/utils";

/** iOS-style switch, themed with the brand color. `sm` is for dense lists,
 *  where the settings-row size dominates every row it sits in. */
function Toggle({
  checked,
  onCheckedChange,
  size = "md",
}: {
  checked: boolean;
  onCheckedChange: (value: boolean) => void;
  size?: "md" | "sm";
}) {
  const small = size === "sm";
  return (
    <label className="relative inline-flex flex-none cursor-pointer select-none">
      <input
        type="checkbox"
        className="peer sr-only"
        checked={checked}
        onChange={(e) => onCheckedChange(e.target.checked)}
      />
      <span
        className={cn(
          small ? "h-[16px] w-[28px]" : "h-[22px] w-[38px]",
          "rounded-full bg-accent transition-colors duration-200",
          "shadow-[inset_0_0_0_1px_var(--border)]",
          "peer-checked:bg-primary peer-checked:shadow-none",
        )}
      />
      <span
        className={cn(
          "pointer-events-none absolute top-0.5 left-0.5 rounded-full bg-white",
          small ? "size-[12px]" : "size-[18px]",
          "shadow-[0_1px_2px_rgba(0,0,0,0.35)] transition-transform duration-200",
          small ? "peer-checked:translate-x-3" : "peer-checked:translate-x-4",
        )}
      />
    </label>
  );
}

export { Toggle };
