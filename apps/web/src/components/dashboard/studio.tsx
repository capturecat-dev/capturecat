import type { ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowLeft } from "lucide-react";

import { cn } from "@/lib/utils";

/**
 * The dashboard's shared vocabulary — "studio" because every page is laid
 * out the same way an editing suite is: a compact title bar with a
 * section eyebrow on top, glass panels below, one control shape throughout.
 *
 * Nothing here invents a new surface: `glass-panel` / `hairline-top` are the
 * site's existing liquid-glass utilities and the pill controls are the
 * shadcn Input shape (`.studio-input` for raw elements).
 */

export function Eyebrow({ children, className }: { children: ReactNode; className?: string }) {
  return <span className={cn("studio-eyebrow", className)}>{children}</span>;
}

/**
 * Page title bar. Every /app page opens with one, so titles, descriptions,
 * back links and action clusters sit in the same place everywhere.
 */
export function PageHeader({
  eyebrow,
  title,
  description,
  back,
  meta,
  actions,
  className,
}: {
  /** Section label above the title, e.g. "Library" or "Video". */
  eyebrow?: ReactNode;
  title: ReactNode;
  description?: ReactNode;
  /** Renders a back link above the eyebrow. */
  back?: { to: "/app" | "/app/team" | "/app/settings" | "/app/billing"; label: string };
  /** Right-aligned secondary info (a storage meter, a status line). */
  meta?: ReactNode;
  /** Right-aligned buttons. */
  actions?: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("flex flex-wrap items-end justify-between gap-x-6 gap-y-3", className)}>
      <div className="min-w-0">
        {back && (
          <Link
            to={back.to}
            className="mb-2 inline-flex items-center gap-1.5 text-[13px] text-muted-foreground transition-colors hover:text-foreground"
          >
            <ArrowLeft className="size-3.5" /> {back.label}
          </Link>
        )}
        {eyebrow && (
          <div className="mb-1">
            <Eyebrow>{eyebrow}</Eyebrow>
          </div>
        )}
        <h1 className="truncate text-[22px] font-semibold leading-tight tracking-[-0.02em]">
          {title}
        </h1>
        {description && (
          <p className="mt-1 max-w-2xl text-sm text-muted-foreground">{description}</p>
        )}
      </div>
      {(meta || actions) && (
        <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
          {meta}
          {actions && <div className="flex items-center gap-2">{actions}</div>}
        </div>
      )}
    </div>
  );
}

/** The heading row shared by Panel and Section. */
function Heading({
  title,
  description,
  icon,
  badge,
  actions,
}: {
  title?: ReactNode;
  description?: ReactNode;
  icon?: ReactNode;
  badge?: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <div className="flex items-start justify-between gap-4">
      <div className="min-w-0">
        {title && (
          <h2 className="flex items-center gap-2 text-sm font-semibold">
            {icon && <span className="text-muted-foreground [&>svg]:size-4">{icon}</span>}
            <span className="truncate">{title}</span>
            {badge}
          </h2>
        )}
        {description && (
          <p className="mt-1 text-[13px] leading-relaxed text-muted-foreground">{description}</p>
        )}
      </div>
      {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
    </div>
  );
}

/**
 * ONE surface per page. Pages never lay cards side by side; related groups
 * stack inside a single glass panel as Sections divided by hairlines, the
 * way System Settings groups rows. Use this for settings-style pages.
 */
export function Sections({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <section className={cn("glass-panel hairline-top divide-y divide-white/8 overflow-hidden", className)}>
      {children}
    </section>
  );
}

/** One group inside `Sections`: heading row + content, no surface of its own. */
export function Section({
  title,
  description,
  icon,
  badge,
  actions,
  children,
  className,
}: {
  title?: ReactNode;
  description?: ReactNode;
  icon?: ReactNode;
  badge?: ReactNode;
  actions?: ReactNode;
  children?: ReactNode;
  className?: string;
}) {
  const hasHeading = title || description || actions;
  return (
    <div className={cn("min-w-0 p-5", className)}>
      {hasHeading && <Heading title={title} description={description} icon={icon} badge={badge} actions={actions} />}
      {children && <div className={cn(hasHeading && "mt-4")}>{children}</div>}
    </div>
  );
}

/** A glass panel with the standard heading row — for pages with ONE group
 *  (an empty state, a single form). Groups on a page go in `Sections`. */
export function Panel({
  title,
  description,
  icon,
  badge,
  actions,
  children,
  className,
  padding = "p-5",
  as: Tag = "section",
}: {
  title?: ReactNode;
  description?: ReactNode;
  icon?: ReactNode;
  /** A PlanChip or Badge next to the title. */
  badge?: ReactNode;
  /** Right-aligned controls in the heading row. */
  actions?: ReactNode;
  children?: ReactNode;
  className?: string;
  padding?: string;
  as?: "section" | "div" | "article";
}) {
  const hasHeading = title || description || actions;
  return (
    <Tag className={cn("glass-panel hairline-top min-w-0", padding, className)}>
      {hasHeading && <Heading title={title} description={description} icon={icon} badge={badge} actions={actions} />}
      {children && <div className={cn(hasHeading && "mt-4")}>{children}</div>}
    </Tag>
  );
}

/** A list row inside a panel. */
export function Row({
  children,
  className,
  dashed = false,
}: {
  children: ReactNode;
  className?: string;
  dashed?: boolean;
}) {
  return (
    <div className={cn("studio-row", dashed && "studio-row-dashed", className)}>{children}</div>
  );
}

/** Label + control + hint, stacked. */
export function Field({
  label,
  hint,
  error,
  children,
  className,
}: {
  label: ReactNode;
  hint?: ReactNode;
  error?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <label className={cn("block min-w-0 space-y-1.5", className)}>
      <span className="studio-eyebrow block">{label}</span>
      {children}
      {error ? (
        <span className="block text-xs text-destructive">{error}</span>
      ) : hint ? (
        <span className="block text-xs text-muted-foreground">{hint}</span>
      ) : null}
    </label>
  );
}

/** The plan a feature belongs to. One look everywhere. */
export function PlanChip({ plan }: { plan: "pro" | "business" }) {
  return (
    <span className="inline-flex h-5 items-center rounded-full border border-white/12 bg-white/[0.06] px-2 text-[10px] font-semibold uppercase tracking-[0.08em] text-foreground/80">
      {plan === "pro" ? "Pro" : "Business"}
    </span>
  );
}

/** Dashed empty state inside a panel. */
export function EmptyNote({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div
      className={cn(
        "flex min-h-24 items-center justify-center rounded-xl border border-dashed border-white/12 px-4 py-6 text-center text-sm text-muted-foreground",
        className,
      )}
    >
      {children}
    </div>
  );
}

/** Inline upgrade nudge under a gated feature. */
export function UpgradeNote({ plan, children }: { plan: "pro" | "business"; children?: ReactNode }) {
  return (
    <p className="mt-3 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
      <PlanChip plan={plan} />
      <span>
        {children ??
          (plan === "pro"
            ? "This is a Pro feature."
            : "This is a Business feature.")}{" "}
        <Link to="/app/billing" className="text-foreground underline underline-offset-4">
          See plans
        </Link>
      </span>
    </p>
  );
}

/** Big number + micro label, for stat rows. */
export function StatTile({
  value,
  label,
  accent,
  hint,
}: {
  value: ReactNode;
  label: ReactNode;
  /** CSS colour for the dot; omit for none. */
  accent?: string;
  hint?: ReactNode;
}) {
  return (
    <div className="glass-panel hairline-top px-5 py-4">
      <div className="flex items-center gap-2">
        {accent && (
          <span aria-hidden className="size-1.5 shrink-0 rounded-full" style={{ background: accent }} />
        )}
        <Eyebrow>{label}</Eyebrow>
      </div>
      <div className="mt-2 text-2xl font-semibold tabular-nums tracking-[-0.02em]">{value}</div>
      {hint && <div className="mt-1 text-xs text-muted-foreground">{hint}</div>}
    </div>
  );
}
