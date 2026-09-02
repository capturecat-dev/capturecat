import { useMemo } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowLeft } from "lucide-react";
import { areaY, barY, defineChart, lineY } from "@tanstack/charts";
import { crosshair } from "@tanstack/charts/crosshair";
import { scaleBand } from "@tanstack/charts/scales/band";
import { scaleLinear } from "@tanstack/charts/scales/linear";
import { tooltip } from "@tanstack/charts/tooltip";
import { Chart } from "@tanstack/react-charts";

import { trpc } from "@/lib/trpc/client";
import { AnalyticsSkeleton } from "@/components/dashboard/page-skeletons";

/* ------------------------------------------------------------------ */
/* Shared formatting + chart chrome                                    */
/* ------------------------------------------------------------------ */

function formatTime(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

/**
 * Recessive dark-surface chart chrome: hairline grid at white/8, axis text in
 * the app's muted foreground. Charts inherit the rest from the container.
 */
const chartTheme = {
  foreground: "oklch(0.708 0 0)", // --muted-foreground
  muted: "oklch(0.708 0 0 / 70%)",
  grid: "rgba(255, 255, 255, 0.08)",
} as const;

/** Bucket sparse per-second points into `bucketCount` max-value buckets. */
function bucketize(
  points: Array<{ second: number; value: number }>,
  duration: number,
  bucketCount: number
): Array<{ start: number; value: number }> {
  const seconds = Math.max(1, Math.ceil(duration));
  const buckets = Math.max(1, Math.min(bucketCount, seconds));
  const per = seconds / buckets;
  const values = new Array<number>(buckets).fill(0);
  for (const p of points) {
    const b = Math.min(buckets - 1, Math.max(0, Math.floor(p.second / per)));
    values[b] = Math.max(values[b], p.value);
  }
  return values.map((value, i) => ({ start: i * per, value }));
}

/* ------------------------------------------------------------------ */
/* Panels & tiles (liquid-glass surfaces)                              */
/* ------------------------------------------------------------------ */

function Panel({
  title,
  subtitle,
  children,
}: {
  title: string;
  subtitle?: string;
  children: React.ReactNode;
}) {
  return (
    <div className="glass-panel hairline-top min-w-0 overflow-hidden p-5">
      <h2 className="text-sm font-medium">{title}</h2>
      {subtitle && <p className="mt-0.5 text-xs text-muted-foreground">{subtitle}</p>}
      <div className="mt-4 min-w-0">{children}</div>
    </div>
  );
}

function StatTile({
  value,
  label,
  accent,
}: {
  value: string;
  label: string;
  accent: string;
}) {
  return (
    <div className="glass-panel hairline-top px-5 py-4">
      <div className="flex items-center gap-2">
        <span
          aria-hidden
          className="h-1.5 w-1.5 shrink-0 rounded-full"
          style={{ background: accent }}
        />
        <span className="text-[11px] font-medium uppercase tracking-[0.08em] text-muted-foreground">
          {label}
        </span>
      </div>
      <div className="mt-2 text-2xl font-semibold tabular-nums tracking-[-0.02em]">
        {value}
      </div>
    </div>
  );
}

function EmptyState({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-32 items-center justify-center rounded-xl border border-dashed border-white/10 text-sm text-muted-foreground">
      {children}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Charts                                                              */
/* ------------------------------------------------------------------ */

/**
 * Watch heatmap — a single ordered series (viewers per moment), so an area
 * chart: 2px line, gradient wash fading to transparent, crosshair + tooltip.
 */
function WatchAreaChart({
  duration,
  points,
}: {
  duration: number;
  points: Array<{ second: number; value: number }>;
}) {
  const rows = useMemo(() => bucketize(points, duration, 60), [points, duration]);

  const definition = useMemo(() => {
    return defineChart({
      marks: [
        areaY(rows, { x: "start", y: "value", fill: "url(#watch-fill)" }),
        lineY(rows, {
          x: "start",
          y: "value",
          stroke: "var(--chart-2)",
          strokeWidth: 2,
        }),
        crosshair({ x: { label: false }, y: false }),
      ],
      x: {
        scale: scaleLinear,
        axis: { ticks: { format: (v: number) => formatTime(v) } },
      },
      y: {
        scale: scaleLinear,
        nice: true,
        grid: true,
        axis: { ticks: { count: 4, format: (v: number) => String(Math.round(v)) } },
      },
      gradients: [
        {
          id: "watch-fill",
          x1: 0,
          y1: 1,
          x2: 0,
          y2: 0,
          stops: [
            { offset: 0, color: "var(--chart-2)", opacity: 0 },
            { offset: 1, color: "var(--chart-2)", opacity: 0.28 },
          ],
        },
      ],
      clip: true,
      focus: "nearest-x",
      maxFocusDistance: Number.POSITIVE_INFINITY,
      theme: chartTheme,
      tooltip: {
        use: tooltip,
        format: (point) =>
          `${point.datum.value.toLocaleString()} viewers · ${formatTime(point.datum.start)}`,
      },
    });
  }, [rows]);

  return (
    <div className="min-w-0 text-muted-foreground">
      <Chart definition={definition} height={220} ariaLabel="Viewers per moment of the video" />
    </div>
  );
}

/**
 * Time-bucketed bar chart (drop-off / clicks). Muted single hue; optionally
 * the peak bucket is emphasized at full strength.
 */
function TimeBarChart({
  duration,
  points,
  hue,
  emphasizePeak,
  height = 200,
  buckets = 24,
  tooltipLabel,
  ariaLabel,
}: {
  duration: number;
  points: Array<{ second: number; value: number }>;
  hue: string;
  emphasizePeak?: boolean;
  height?: number;
  buckets?: number;
  tooltipLabel: string;
  ariaLabel: string;
}) {
  const rows = useMemo(
    () => bucketize(points, duration, buckets),
    [points, duration, buckets]
  );
  const peak = useMemo(
    () => rows.reduce((m, r) => (r.value > m.value ? r : m), rows[0]),
    [rows]
  );

  const definition = useMemo(() => {
    return defineChart({
      marks: [
        barY(rows, {
          x: "start",
          y: "value",
          radius: 3,
          fill: (d) =>
            emphasizePeak && d.value !== peak.value
              ? `color-mix(in oklab, ${hue} 38%, transparent)`
              : hue,
        }),
      ],
      x: {
        scale: () => scaleBand<number>().padding(0.18),
        axis: {
          ticks: { format: (v: number) => formatTime(v) },
          tickLabels: { thin: { minGap: 12 } },
        },
      },
      y: {
        scale: scaleLinear,
        nice: true,
        grid: true,
        axis: { ticks: { count: 4, format: (v: number) => String(Math.round(v)) } },
      },
      theme: chartTheme,
      tooltip: {
        use: tooltip,
        format: (point) =>
          `${point.datum.value.toLocaleString()} ${tooltipLabel} · ${formatTime(point.datum.start)}`,
      },
    });
  }, [rows, peak, hue, emphasizePeak, tooltipLabel]);

  return (
    <div className="min-w-0 text-muted-foreground">
      <Chart definition={definition} height={height} ariaLabel={ariaLabel} />
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Ranked lists (countries / referrers)                                */
/* ------------------------------------------------------------------ */

function RankList({ rows }: { rows: Array<{ label: string; count: number }> }) {
  const max = Math.max(1, ...rows.map((r) => r.count));
  if (rows.length === 0) return <EmptyState>No data yet.</EmptyState>;
  return (
    <div className="space-y-3">
      {rows.map((r) => (
        <div key={r.label}>
          <div className="flex items-baseline justify-between gap-3 text-sm">
            <span className="truncate">{r.label}</span>
            <span className="shrink-0 tabular-nums text-muted-foreground">
              {r.count.toLocaleString()}
            </span>
          </div>
          <div className="mt-1.5 h-[3px] overflow-hidden rounded-full bg-white/[0.06]">
            <div
              className="h-full rounded-full bg-white/30"
              style={{ width: `${(r.count / max) * 100}%` }}
            />
          </div>
        </div>
      ))}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Page                                                                */
/* ------------------------------------------------------------------ */

export function VideoAnalytics({ videoId }: { videoId: string }) {
  const { data, isLoading, error } = trpc.videos.analytics.useQuery({ videoId });

  if (isLoading) {
    return <AnalyticsSkeleton />;
  }
  if (error || !data) {
    return (
      <p className="py-20 text-center text-muted-foreground">
        {error?.message ?? "Could not load analytics."}
      </p>
    );
  }

  const completionRate = data.plays > 0 ? Math.round((data.completions / data.plays) * 100) : 0;
  const biggestDrop = [...data.dropOff].sort((a, b) => b.sessions - a.sessions)[0];

  return (
    <div className="min-w-0 space-y-6">
      <div>
        <Link
          to="/app"
          className="inline-flex items-center gap-1.5 text-sm text-muted-foreground transition-colors hover:text-foreground"
        >
          <ArrowLeft className="h-4 w-4" /> My Videos
        </Link>
        <h1 className="mt-2 text-2xl font-bold tracking-tight">Analytics</h1>
        <p className="text-muted-foreground">
          Who watched, where they stopped, and what they did.
        </p>
      </div>

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <StatTile value={data.views.toLocaleString()} label="Views" accent="var(--chart-2)" />
        <StatTile
          value={data.plays.toLocaleString()}
          label="Pressed play"
          accent="var(--chart-1)"
        />
        <StatTile
          value={formatTime(data.avgWatchedSeconds)}
          label="Avg. watch point"
          accent="var(--chart-3)"
        />
        <StatTile
          value={`${completionRate}%`}
          label="Watched to end"
          accent="var(--chart-4)"
        />
      </div>

      {data.ctaLabel && (
        <Panel title={`Funnel — play → watch → "${data.ctaLabel}" clicks`}>
          <div className="space-y-2.5">
            {[
              { label: "Pressed play", value: data.plays },
              { label: "Watched to the end", value: data.completions },
              { label: `Clicked "${data.ctaLabel}"`, value: data.ctaClicks },
            ].map((step, i, steps) => {
              const base = Math.max(1, steps[0].value);
              const pct = Math.round((step.value / base) * 100);
              // Ordinal ramp: one hue, stepping lighter down the funnel.
              const strength = [0.85, 0.55, 0.32][i];
              return (
                <div key={step.label} className="flex items-center gap-3">
                  <div className="w-44 shrink-0 truncate text-sm text-muted-foreground">
                    {step.label}
                  </div>
                  <div className="h-4 min-w-0 flex-1 overflow-hidden rounded-full bg-white/[0.05]">
                    <div
                      className="h-full rounded-full"
                      style={{
                        width: `${Math.max(pct, step.value > 0 ? 2 : 0)}%`,
                        background: `color-mix(in oklab, var(--chart-2) ${strength * 100}%, transparent)`,
                      }}
                    />
                  </div>
                  <div className="w-20 shrink-0 text-right text-sm tabular-nums text-muted-foreground">
                    <span className="text-foreground">{step.value.toLocaleString()}</span>
                    {" · "}
                    {pct}%
                  </div>
                </div>
              );
            })}
          </div>
        </Panel>
      )}

      <Panel
        title="Watch heatmap"
        subtitle="How many viewers saw each moment of the video"
      >
        {data.watchHeatmap.length === 0 ? (
          <EmptyState>No watch data yet.</EmptyState>
        ) : (
          <WatchAreaChart
            duration={data.durationSeconds}
            points={data.watchHeatmap.map((h) => ({ second: h.second, value: h.viewers }))}
          />
        )}
      </Panel>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Panel title="Where viewers stopped" subtitle="Sessions ending in each time bucket">
          {data.dropOff.length === 0 ? (
            <EmptyState>No drop-off data yet.</EmptyState>
          ) : (
            <>
              <TimeBarChart
                duration={data.durationSeconds}
                points={data.dropOff.map((d) => ({ second: d.second, value: d.sessions }))}
                hue="color-mix(in oklab, var(--chart-1) 72%, white)"
                emphasizePeak
                tooltipLabel="sessions ended"
                ariaLabel="Sessions ending per time bucket"
              />
              {biggestDrop && (
                <p className="mt-3 text-sm text-muted-foreground">
                  Most viewers stopped around{" "}
                  <span className="text-foreground">{formatTime(biggestDrop.second)}</span>.
                </p>
              )}
            </>
          )}
        </Panel>

        <Panel title="Player clicks by moment" subtitle="Where viewers clicked in the player">
          {data.clicks.length === 0 ? (
            <EmptyState>No clicks recorded yet.</EmptyState>
          ) : (
            <TimeBarChart
              duration={data.durationSeconds}
              points={data.clicks.map((c) => ({ second: c.second, value: c.count }))}
              hue="var(--chart-4)"
              tooltipLabel="clicks"
              ariaLabel="Player clicks per time bucket"
            />
          )}
        </Panel>

        <Panel title="Countries">
          <RankList rows={data.countries.map((c) => ({ label: c.country, count: c.count }))} />
        </Panel>

        <Panel title="Referrers">
          <RankList
            rows={data.referrers.map((r) => ({ label: r.referrer, count: r.count }))}
          />
        </Panel>
      </div>

      <Panel title={`Comments (${data.comments.length})`}>
        {data.comments.length === 0 ? (
          <EmptyState>No comments yet.</EmptyState>
        ) : (
          <div className="space-y-4">
            {data.comments.map((cm) => (
              <div key={cm.commentId} className="border-b border-white/8 pb-3 last:border-0">
                <div className="flex items-center gap-2 text-sm">
                  <span className="font-medium">{cm.authorName}</span>
                  {data.projectId ? (
                    <a
                      href={`capturecat://open-project?id=${data.projectId}&t=${Math.floor(cm.videoTime)}`}
                      title="Open in CaptureCat at this moment"
                      className="rounded bg-white/[0.07] px-1.5 py-0.5 text-xs tabular-nums text-muted-foreground transition-colors hover:bg-white/[0.15] hover:text-foreground"
                    >
                      {formatTime(cm.videoTime)} ↗
                    </a>
                  ) : (
                    <span className="rounded bg-white/[0.07] px-1.5 py-0.5 text-xs tabular-nums text-muted-foreground">
                      {formatTime(cm.videoTime)}
                    </span>
                  )}
                  <span className="text-xs text-muted-foreground">
                    {new Date(cm.createdAt).toLocaleDateString()}
                  </span>
                </div>
                <p className="mt-1 text-sm text-muted-foreground">{cm.body}</p>
              </div>
            ))}
          </div>
        )}
      </Panel>
    </div>
  );
}
