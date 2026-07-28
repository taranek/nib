import { ChevronDown } from "lucide-react";

import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "./dropdown-menu";

/** A select option: a plain string, or a value with a muted description line. */
export type SelectOption = string | { value: string; description?: string };

const valueOf = (o: SelectOption) => (typeof o === "string" ? o : o.value);

/** Compact select built on the dropdown menu (radio options). */
function Select({
  value,
  options,
  onValueChange,
}: {
  value: string;
  options: SelectOption[];
  onValueChange: (value: string) => void;
}) {
  return (
    <DropdownMenu modal={false}>
      <DropdownMenuTrigger asChild>
        <button className="inline-flex h-7 flex-none cursor-pointer items-center gap-1.5 rounded-md border border-border bg-accent px-2.5 text-[13px] text-foreground transition-[background-color,border-color] duration-150 hover:border-hairline-strong hover:bg-accent-hover">
          {value}
          <ChevronDown className="size-3.5 opacity-60" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="end"
        className="max-h-(--radix-dropdown-menu-content-available-height) min-w-40 overflow-y-auto"
      >
        <DropdownMenuRadioGroup value={value} onValueChange={onValueChange}>
          {options.map((o) => {
            const v = valueOf(o);
            const description =
              typeof o === "string" ? undefined : o.description;
            return (
              <DropdownMenuRadioItem key={v} value={v}>
                {description ? (
                  <span className="flex min-w-0 flex-col gap-px">
                    <span>{v}</span>
                    <span className="text-[11px] text-muted-foreground">
                      {description}
                    </span>
                  </span>
                ) : (
                  v
                )}
              </DropdownMenuRadioItem>
            );
          })}
        </DropdownMenuRadioGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

export { Select };
