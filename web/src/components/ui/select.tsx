import { ChevronDown } from "lucide-react";

import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "./dropdown-menu";

/** Compact select built on the dropdown menu (radio options). */
function Select({
  value,
  options,
  onValueChange,
}: {
  value: string;
  options: string[];
  onValueChange: (value: string) => void;
}) {
  return (
    <DropdownMenu modal={false}>
      <DropdownMenuTrigger asChild>
        <button className="inline-flex h-7 flex-none cursor-pointer items-center gap-1.5 rounded-md border border-border bg-accent px-2.5 text-[13px] text-foreground transition-[background-color,border-color] duration-150 hover:border-border-strong hover:bg-accent-hover">
          {value}
          <ChevronDown className="size-3.5 opacity-60" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="end"
        className="max-h-(--radix-dropdown-menu-content-available-height) min-w-40 overflow-y-auto"
      >
        <DropdownMenuRadioGroup value={value} onValueChange={onValueChange}>
          {options.map((o) => (
            <DropdownMenuRadioItem key={o} value={o}>
              {o}
            </DropdownMenuRadioItem>
          ))}
        </DropdownMenuRadioGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

export { Select };
