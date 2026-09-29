import { Skeleton } from "@/components/ui/skeleton";

/**
 * Polaris-style page skeletons: every loading state mirrors the LAYOUT of the
 * page it stands in for (Shopify's SkeletonPage/SkeletonBodyText pattern) —
 * a title ghost, then panel/table ghosts shaped like the real content — so
 * the page doesn't jump when data lands. Ghost surfaces are the same glass
 * panels the real pages use. Use these instead of PageSpinner.
 */

/** SkeletonDisplayText — the page title ghost. */
export function SkeletonTitle({ wide = false }: { wide?: boolean }) {
  return (
    <div className="space-y-2">
      <Skeleton className="h-3 w-16 opacity-60" />
      <Skeleton className={wide ? "h-7 w-64" : "h-7 w-40"} />
      <Skeleton className="h-4 w-72 opacity-60" />
    </div>
  );
}

/** SkeletonBodyText — n lines, last one short. */
export function SkeletonLines({ lines = 3 }: { lines?: number }) {
  return (
    <div className="space-y-2">
      {Array.from({ length: lines }, (_, i) => (
        <Skeleton
          key={i}
          className="h-3.5"
          style={{ width: i === lines - 1 ? "60%" : "100%" }}
        />
      ))}
    </div>
  );
}

/** A glass panel ghost with an optional heading row. */
export function SkeletonCard({
  lines = 3,
  action = false,
}: {
  lines?: number;
  action?: boolean;
}) {
  return (
    <div className="glass-panel hairline-top p-5">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Skeleton className="size-4 rounded" />
          <Skeleton className="h-4 w-32" />
        </div>
        {action && <Skeleton className="h-8 w-24 rounded-full" />}
      </div>
      <div className="mt-4">
        <SkeletonLines lines={lines} />
      </div>
    </div>
  );
}

/** Table ghost: header row + n data rows. */
export function SkeletonTable({ rows = 6 }: { rows?: number }) {
  return (
    <div className="glass-panel hairline-top overflow-hidden">
      <div className="flex items-center gap-4 border-b border-white/8 px-4 py-3">
        <Skeleton className="h-3.5 w-32" />
        <Skeleton className="ml-auto h-3.5 w-20" />
        <Skeleton className="h-3.5 w-16" />
      </div>
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} className="flex items-center gap-4 border-b border-white/8 px-4 py-3.5 last:border-b-0">
          <Skeleton className="h-9 w-14 shrink-0 rounded-md" />
          <div className="min-w-0 flex-1 space-y-1.5">
            <Skeleton className="h-3.5" style={{ width: `${45 + ((i * 17) % 35)}%` }} />
            <Skeleton className="h-3 w-24 opacity-60" />
          </div>
          <Skeleton className="h-3.5 w-20" />
          <Skeleton className="size-7 rounded-md" />
        </div>
      ))}
    </div>
  );
}

/** Library page: title + toolbar + video table. */
export function LibrarySkeleton() {
  return (
    <div className="space-y-4">
      <div className="flex items-end justify-between">
        <SkeletonTitle />
        <Skeleton className="h-4 w-44 opacity-60" />
      </div>
      <div className="flex items-center gap-2">
        <Skeleton className="h-9 w-56 rounded-full" />
        <Skeleton className="h-9 w-28 rounded-full" />
        <Skeleton className="ml-auto h-9 w-24 rounded-full" />
      </div>
      <SkeletonTable rows={7} />
    </div>
  );
}

/** Team page: members + library + SSO, one surface. */
export function TeamSkeleton() {
  return <SkeletonSections sections={[{ lines: 3, action: true }, { lines: 2 }, { lines: 4, action: true }]} />;
}

/** One surface, hairline-divided sections — the shape Sections renders. */
export function SkeletonSections({ sections }: { sections: Array<{ lines: number; action?: boolean }> }) {
  return (
    <div className="glass-panel hairline-top max-w-3xl divide-y divide-white/8 overflow-hidden">
      {sections.map((s, i) => (
        <div key={i} className="p-5">
          <div className="flex items-center justify-between gap-3">
            <div className="flex items-center gap-2">
              <Skeleton className="size-4 rounded" />
              <Skeleton className="h-4 w-32" />
            </div>
            {s.action && <Skeleton className="h-8 w-24 rounded-full" />}
          </div>
          <div className="mt-4">
            <SkeletonLines lines={s.lines} />
          </div>
        </div>
      ))}
    </div>
  );
}

/** Settings: profile + domains, one surface. */
export function SettingsSkeleton() {
  return <SkeletonSections sections={[{ lines: 4, action: true }, { lines: 3 }]} />;
}

/** Billing: plan + storage, one surface. */
export function BillingSkeleton() {
  return <SkeletonSections sections={[{ lines: 2, action: true }, { lines: 2 }]} />;
}

/** Video detail: title + settings column + player column. */
export function VideoDetailSkeleton() {
  return (
    <div className="space-y-6">
      <div className="flex items-end justify-between">
        <SkeletonTitle wide />
        <Skeleton className="h-8 w-28 rounded-full" />
      </div>
      <div className="grid gap-6 lg:grid-cols-[1fr_380px]">
        <div className="space-y-4">
          <SkeletonCard lines={3} />
          <SkeletonCard lines={4} />
        </div>
        <div className="space-y-4">
          <Skeleton className="aspect-video w-full rounded-2xl" />
          <SkeletonCard lines={2} />
        </div>
      </div>
    </div>
  );
}

/** Analytics: title + stat tiles + chart ghost + table. */
export function AnalyticsSkeleton() {
  return (
    <div className="space-y-6">
      <SkeletonTitle />
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        {Array.from({ length: 4 }, (_, i) => (
          <div key={i} className="glass-panel hairline-top px-5 py-4">
            <Skeleton className="h-3 w-20 opacity-60" />
            <Skeleton className="mt-2 h-7 w-16" />
          </div>
        ))}
      </div>
      <div className="glass-panel hairline-top p-5">
        <Skeleton className="h-3.5 w-32" />
        <Skeleton className="mt-4 h-48 w-full rounded-xl" />
      </div>
      <SkeletonTable rows={4} />
    </div>
  );
}
