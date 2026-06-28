import { cn } from "@/lib/utils";

/** iOS-style switch, themed with the brand color. */
function Toggle({
  checked,
  onCheckedChange,
}: {
  checked: boolean;
  onCheckedChange: (value: boolean) => void;
}) {
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
          "h-[22px] w-[38px] rounded-full bg-accent transition-colors duration-200",
          "shadow-[inset_0_0_0_1px_var(--border)]",
          "peer-checked:bg-primary peer-checked:shadow-none",
        )}
      />
      <span
        className={cn(
          "pointer-events-none absolute top-0.5 left-0.5 size-[18px] rounded-full bg-white",
          "shadow-[0_1px_2px_rgba(0,0,0,0.35)] transition-transform duration-200",
          "peer-checked:translate-x-4",
        )}
      />
    </label>
  );
}

export { Toggle };
