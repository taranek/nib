import { cn } from "@/lib/utils";

/** Small status dot — green when ok, amber otherwise. */
function StatusDot({ ok, className }: { ok: boolean; className?: string }) {
  return (
    <span
      data-slot="status-dot"
      className={cn("size-[9px] flex-none rounded-full", className)}
      style={{ background: ok ? "var(--diff-ins)" : "#e0a64a" }}
    />
  );
}

export { StatusDot };
