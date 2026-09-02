import { Skeleton } from "@/components/ui/skeleton";

/**
 * Polaris-style page skeletons: every loading state mirrors the LAYOUT of the
 * page it stands in for (Shopify's SkeletonPage/SkeletonBodyText pattern) —
 * a title ghost, then card/table ghosts shaped like the real content — so
 * the page doesn't jump when data lands. Use these instead of PageSpinner.
 */

/** SkeletonDisplayText — the page title ghost. */
export function SkeletonTitle({ wide = false }: { wide?: boolean }) {
  return (
    <div className="space-y-2">
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

/** A bordered card ghost with an optional heading row. */
export function SkeletonCard({
  lines = 3,
  action = false,
}: {
  lines?: number;
  action?: boolean;
}) {
  return (
    <div className="rounded-lg border p-4">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Skeleton className="h-4 w-4 rounded" />
          <Skeleton className="h-4 w-32" />
        </div>
        {action && <Skeleton className="h-8 w-24 rounded-md" />}
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
    <div className="rounded-lg border">
      <div className="flex items-center gap-4 border-b px-4 py-3">
        <Skeleton className="h-3.5 w-32" />
        <Skeleton className="ml-auto h-3.5 w-20" />
        <Skeleton className="h-3.5 w-16" />
      </div>
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} className="flex items-center gap-4 border-b px-4 py-3.5 last:border-b-0">
          <Skeleton className="h-9 w-14 shrink-0 rounded-md" />
          <div className="min-w-0 flex-1 space-y-1.5">
            <Skeleton className="h-3.5" style={{ width: `${45 + ((i * 17) % 35)}%` }} />
            <Skeleton className="h-3 w-24 opacity-60" />
          </div>
          <Skeleton className="h-3.5 w-20" />
          <Skeleton className="h-7 w-7 rounded-md" />
        </div>
      ))}
    </div>
  );
}

/** Library page: toolbar + video table. */
export function LibrarySkeleton() {
  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <Skeleton className="h-9 w-56 rounded-md" />
        <Skeleton className="h-9 w-28 rounded-md" />
        <Skeleton className="ml-auto h-9 w-24 rounded-md" />
      </div>
      <SkeletonTable rows={7} />
    </div>
  );
}

/** Team page: members card + library card + SSO card. */
export function TeamSkeleton() {
  return (
    <div className="space-y-6">
      <div className="rounded-lg border p-4">
        <div className="flex items-center gap-3">
          <Skeleton className="h-10 w-10 rounded-lg" />
          <div className="flex-1 space-y-1.5">
            <Skeleton className="h-4 w-36" />
            <Skeleton className="h-3 w-20 opacity-60" />
          </div>
          <Skeleton className="h-8 w-24 rounded-md" />
        </div>
        <div className="mt-4 space-y-2">
          {Array.from({ length: 3 }, (_, i) => (
            <div key={i} className="flex items-center justify-between rounded-md border px-3 py-2.5">
              <Skeleton className="h-3.5 w-44" />
              <Skeleton className="h-5 w-14 rounded-full" />
            </div>
          ))}
        </div>
      </div>
      <SkeletonCard lines={2} />
      <SkeletonCard lines={4} action />
    </div>
  );
}

/** Settings: profile card + domains card. */
export function SettingsSkeleton() {
  return (
    <div className="space-y-6">
      <SkeletonCard lines={4} action />
      <SkeletonCard lines={3} />
    </div>
  );
}

/** Billing: status card with a plan line and action button. */
export function BillingSkeleton() {
  return (
    <div className="rounded-lg border p-6">
      <div className="flex items-center gap-3">
        <Skeleton className="h-10 w-10 rounded-lg" />
        <div className="space-y-1.5">
          <Skeleton className="h-4 w-28" />
          <Skeleton className="h-3 w-48 opacity-60" />
        </div>
      </div>
      <div className="mt-6 space-y-2">
        <SkeletonLines lines={2} />
      </div>
      <Skeleton className="mt-6 h-9 w-48 rounded-md" />
    </div>
  );
}

/** Video detail: player ghost + meta + settings rows. */
export function VideoDetailSkeleton() {
  return (
    <div className="space-y-4">
      <Skeleton className="aspect-video w-full rounded-lg" />
      <div className="flex items-center justify-between">
        <div className="space-y-1.5">
          <Skeleton className="h-5 w-64" />
          <Skeleton className="h-3.5 w-32 opacity-60" />
        </div>
        <Skeleton className="h-9 w-28 rounded-md" />
      </div>
      <SkeletonCard lines={3} />
    </div>
  );
}

/** Analytics: stat tiles + chart ghost + table. */
export function AnalyticsSkeleton() {
  return (
    <div className="space-y-4">
      <div className="grid gap-3 sm:grid-cols-3">
        {Array.from({ length: 3 }, (_, i) => (
          <div key={i} className="rounded-lg border p-4">
            <Skeleton className="h-3 w-20 opacity-60" />
            <Skeleton className="mt-2 h-7 w-16" />
          </div>
        ))}
      </div>
      <div className="rounded-lg border p-4">
        <Skeleton className="h-3.5 w-32" />
        <Skeleton className="mt-3 h-48 w-full rounded-md" />
      </div>
      <SkeletonTable rows={4} />
    </div>
  );
}
