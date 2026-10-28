import type { ReactNode } from "react";

/**
 * An in-cell magnitude bar: a thin single-hue meter behind a number, so a
 * column of counts reads as a ranking at a glance. The number stays in text
 * ink; the bar only carries magnitude.
 */
export function Meter({ value, max, children }: { value: number; max: number; children: ReactNode }) {
  const pct = max > 0 ? Math.max(value > 0 ? 2 : 0, (value / max) * 100) : 0;
  return (
    <div className="flex min-w-[7rem] items-center gap-2">
      <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-muted">
        <div className="h-full rounded-full" style={{ width: `${pct}%`, background: "var(--chart-1)" }} />
      </div>
      <span className="w-14 text-right tabular-nums">{children}</span>
    </div>
  );
}
