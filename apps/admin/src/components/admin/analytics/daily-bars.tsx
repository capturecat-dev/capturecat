import { useMemo, useState } from "react";

import { formatNumber } from "@/lib/format";

/**
 * One metric over time as bars — a small multiple. The page shows visits,
 * downloads, sign-ups and uploads as four of these rather than one combined
 * chart: their scales differ by orders of magnitude, and a shared or second
 * axis would flatten or mislead. Single series, so no legend: the title names
 * it. Over 90 days the bars become weeks so each stays wide enough to read
 * and to hover.
 */
export function DailyBars({
  title,
  points,
}: {
  title: string;
  points: Array<{ day: string; value: number }>;
}) {
  const [hover, setHover] = useState<number | null>(null);

  const bars = useMemo(() => {
    if (points.length <= 90) return points.map((p) => ({ label: fmtDay(p.day), value: p.value }));
    const weeks: Array<{ label: string; value: number }> = [];
    for (let i = 0; i < points.length; i += 7) {
      const chunk = points.slice(i, i + 7);
      weeks.push({
        label: `${fmtDay(chunk[0]!.day)} – ${fmtDay(chunk[chunk.length - 1]!.day)}`,
        value: chunk.reduce((a, p) => a + p.value, 0),
      });
    }
    return weeks;
  }, [points]);

  const total = points.reduce((a, p) => a + p.value, 0);
  const peak = Math.max(0, ...bars.map((b) => b.value));
  const max = Math.max(1, peak);
  const active = hover === null ? null : bars[hover];

  return (
    <figure className="flex min-w-0 flex-col gap-3">
      <figcaption className="flex items-baseline justify-between gap-2">
        <span className="text-sm font-medium">{title}</span>
        <span className="text-sm tabular-nums text-muted-foreground">{formatNumber(total)}</span>
      </figcaption>
      <div className="relative">
        {active && hover !== null && (
          // Inside the plot, and shifted by its own position so the first and
          // last columns' tips stay within the card instead of clipping.
          <div
            className="pointer-events-none absolute top-5 z-10 whitespace-nowrap rounded-md border bg-popover px-2 py-1 text-xs shadow-md"
            style={{
              left: `${((hover + 0.5) / bars.length) * 100}%`,
              transform: `translateX(-${((hover + 0.5) / bars.length) * 100}%)`,
            }}
          >
            <span className="text-muted-foreground">{active.label}</span>{" "}
            <span className="font-medium tabular-nums">{formatNumber(active.value)}</span>
          </div>
        )}
        {/* The scale, above the plot so it never sits on the latest bar. */}
        <div className="mb-1 text-[10px] tabular-nums text-muted-foreground">
          peak {formatNumber(peak)} / {points.length > 90 ? "week" : "day"}
        </div>
        <div
          className="flex h-28 items-end border-b border-border"
          style={{ gap: bars.length > 45 ? 1 : 2 }}
          onMouseLeave={() => setHover(null)}
          role="img"
          aria-label={`${title}: ${formatNumber(total)} in total`}
        >
          {bars.map((b, i) => (
            // The whole column is the hit target, not just the bar.
            <div
              key={b.label}
              className="flex h-full min-w-0 flex-1 items-end rounded-sm transition-colors data-[on=true]:bg-muted/50"
              data-on={hover === i}
              onMouseEnter={() => setHover(i)}
            >
              {b.value > 0 && (
                <div
                  className="w-full rounded-t-[3px]"
                  style={{ height: `${Math.max(2, (b.value / max) * 100)}%`, background: "var(--chart-1)" }}
                />
              )}
            </div>
          ))}
        </div>
        <div className="mt-1 flex justify-between text-[10px] text-muted-foreground">
          <span>{bars[0]?.label.split(" – ")[0]}</span>
          <span>{bars[bars.length - 1]?.label.split(" – ").pop()}</span>
        </div>
      </div>
    </figure>
  );
}

function fmtDay(day: string): string {
  return new Date(`${day}T00:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
}
