import type { CSSProperties, ReactNode } from "react";
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
 * shadcn Input shape (`.studio-input` for raw elements). Motion is the
 * recording bar's family (app.css `--rec-*`, dashboard.css): headers and
 * sections rise in on the settle curve, meters grow and land on the bounce.
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
    <div className={cn("flex flex-wrap items-end justify-between gap-x-6 gap-y-4", className)}>
      <div className="min-w-0">
        {(back || eyebrow) && (
          <div className="dsh-rise mb-2.5 flex items-center gap-2" style={{ "--i": 0 } as CSSProperties}>
            {back && (
              <Link
                to={back.to}
                className="inline-flex h-6 items-center gap-1.5 rounded-full border border-white/10 bg-white/[0.04] pl-2 pr-2.5 text-[12px] text-muted-foreground transition-colors hover:border-white/20 hover:text-foreground"
              >
                <ArrowLeft className="size-3.5" /> {back.label}
              </Link>
            )}
            {eyebrow && <span className="studio-pill-eyebrow">{eyebrow}</span>}
          </div>
        )}
        <h1
          className="dsh-rise truncate text-[26px] font-semibold leading-tight tracking-[-0.025em] md:text-[28px]"
          style={{ "--i": 1 } as CSSProperties}
        >
          {title}
        </h1>
        {description && (
          <p
            className="dsh-rise mt-1.5 max-w-2xl text-sm text-muted-foreground"
            style={{ "--i": 2 } as CSSProperties}
          >
            {description}
          </p>
        )}
      </div>
      {(meta || actions) && (
        <div
          className="dsh-rise flex flex-wrap items-center gap-x-4 gap-y-2"
          style={{ "--i": 2 } as CSSProperties}
        >
          {meta}
          {actions && <div className="flex items-center gap-2">{actions}</div>}
        </div>
      )}
    </div>
  );
}

/** A section icon, set in a raised glass key. */
export function IconKey({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <span aria-hidden className={cn("studio-key", className)}>
      {children}
    </span>
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
      <div className={cn("flex min-w-0 gap-3", icon ? "items-start" : "")}>
        {icon && <IconKey className="mt-[-3px]">{icon}</IconKey>}
        <div className="min-w-0">
          {title && (
            <h2 className="flex items-center gap-2 text-[14px] font-semibold tracking-[-0.01em]">
              <span className="truncate">{title}</span>
              {badge}
            </h2>
          )}
          {description && (
            <p className="mt-1 text-[13px] leading-relaxed text-muted-foreground">{description}</p>
          )}
        </div>
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
    <section
      className={cn(
        "glass-panel hairline-top studio-sections divide-y divide-white/8 overflow-hidden",
        className,
      )}
    >
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
    <div className={cn("min-w-0 p-5 md:p-6", className)}>
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
    <Tag className={cn("glass-panel hairline-top studio-panel dsh-rise min-w-0", padding, className)}>
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
  index,
}: {
  children: ReactNode;
  className?: string;
  dashed?: boolean;
  /** Stagger slot when rows arrive together (with `dsh-rise`). */
  index?: number;
}) {
  return (
    <div
      className={cn("studio-row", dashed && "studio-row-dashed", className)}
      style={index === undefined ? undefined : ({ "--i": index } as CSSProperties)}
    >
      {children}
    </div>
  );
}

/**
 * A settings row: label + description on the left, its control on the
 * right (a switch, a badge). Rows stack with hairlines between them.
 */
export function SettingRow({
  label,
  description,
  children,
  className,
}: {
  label: ReactNode;
  description?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <label className={cn("flex items-center justify-between gap-4 py-3 first:pt-0 last:pb-0", className)}>
      <span className="min-w-0">
        <span className="block text-sm font-medium">{label}</span>
        {description && <span className="mt-0.5 block text-xs text-muted-foreground">{description}</span>}
      </span>
      <span className="flex shrink-0 items-center gap-2">{children}</span>
    </label>
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

/**
 * An empty state that shows the product: a small live recreation of what
 * will happen here (empty-art.tsx) above the title, the line that explains
 * it, and the next step. `compact` sets the art beside the text — for empty
 * groups inside a Section.
 */
export function EmptyStage({
  art,
  title,
  description,
  actions,
  compact = false,
  className,
}: {
  art: ReactNode;
  title: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
  compact?: boolean;
  className?: string;
}) {
  if (compact) {
    return (
      <div
        className={cn(
          "studio-well flex flex-col items-center gap-4 p-4 sm:flex-row sm:gap-5 sm:p-3 sm:pr-5",
          className,
        )}
      >
        <div className="w-full max-w-[220px] shrink-0">{art}</div>
        <div className="min-w-0 text-center sm:text-left">
          <p className="text-sm font-medium">{title}</p>
          {description && <p className="mt-1 text-[13px] leading-relaxed text-muted-foreground">{description}</p>}
          {actions && <div className="mt-3 flex flex-wrap justify-center gap-2 sm:justify-start">{actions}</div>}
        </div>
      </div>
    );
  }
  return (
    <div className={cn("flex flex-col items-center px-4 py-8 text-center md:py-10", className)}>
      <div className="dsh-pop w-full max-w-[360px]">{art}</div>
      <h2 className="dsh-rise mt-6 text-lg font-semibold tracking-[-0.015em]" style={{ "--i": 2 } as CSSProperties}>
        {title}
      </h2>
      {description && (
        <p
          className="dsh-rise mt-1.5 max-w-md text-sm leading-relaxed text-muted-foreground"
          style={{ "--i": 3 } as CSSProperties}
        >
          {description}
        </p>
      )}
      {actions && (
        <div className="dsh-rise mt-5 flex flex-wrap justify-center gap-2" style={{ "--i": 4 } as CSSProperties}>
          {actions}
        </div>
      )}
    </div>
  );
}

/**
 * A meter: track + fill. The fill grows from its leading edge on first
 * paint and lands on the bounce; later changes glide. `tone` defaults from
 * the ratio (amber from 80%, red from 95%) — pass "plain" for rankings.
 */
export function Meter({
  value,
  tone,
  className,
  index = 0,
  label,
}: {
  /** 0…1 */
  value: number;
  tone?: "auto" | "plain";
  className?: string;
  /** Stagger slot for meters that arrive together. */
  index?: number;
  /** Accessible name; omit when the number is printed next to it. */
  label?: string;
}) {
  const v = Math.max(0, Math.min(1, value));
  const t = tone === "plain" ? "plain" : v >= 0.95 ? "full" : v >= 0.8 ? "warn" : undefined;
  return (
    <div
      className={cn("dsh-meter h-1.5", className)}
      data-tone={t}
      role={label ? "meter" : undefined}
      aria-label={label}
      aria-valuenow={label ? Math.round(v * 100) : undefined}
      aria-valuemin={label ? 0 : undefined}
      aria-valuemax={label ? 100 : undefined}
      aria-hidden={label ? undefined : true}
    >
      <i style={{ transform: `scaleX(${v})`, "--i": index } as CSSProperties} />
    </div>
  );
}

/** A status dot whose ring breathes — something is happening right now. */
export function LiveDot({ tone = "cyan", className }: { tone?: "cyan" | "rec" | "amber" | "green"; className?: string }) {
  return (
    <span
      aria-hidden
      className={cn("dsh-live", tone !== "cyan" && `dsh-live--${tone}`, className)}
    />
  );
}

/**
 * Stats as ONE strip: cells divided by hairlines inside a single glass
 * surface (never a row of separate cards). Two columns on phones.
 */
export function StatStrip({
  items,
  className,
}: {
  items: Array<{ label: ReactNode; value: ReactNode; accent?: string; hint?: ReactNode }>;
  className?: string;
}) {
  return (
    <section
      className={cn(
        "glass-panel hairline-top studio-panel grid grid-cols-2 overflow-hidden lg:grid-cols-4",
        className,
      )}
    >
      {items.map((s, i) => (
        <div
          key={i}
          className={cn(
            "dsh-rise min-w-0 border-white/8 px-5 py-4",
            i % 2 === 1 && "border-l",
            i >= 2 && "border-t lg:border-t-0",
            i === 2 && "lg:border-l",
          )}
          style={{ "--i": i + 1 } as CSSProperties}
        >
          <div className="flex items-center gap-2">
            {s.accent && (
              <span
                aria-hidden
                className="size-1.5 shrink-0 rounded-full"
                style={{ background: s.accent, boxShadow: `0 0 8px ${s.accent}` }}
              />
            )}
            <Eyebrow className="truncate">{s.label}</Eyebrow>
          </div>
          <div className="mt-2 text-[26px] font-semibold leading-none tabular-nums tracking-[-0.025em]">{s.value}</div>
          {s.hint && <div className="mt-1.5 text-xs text-muted-foreground">{s.hint}</div>}
        </div>
      ))}
    </section>
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
