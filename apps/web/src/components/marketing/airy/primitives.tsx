import type { ReactNode } from "react";
import { Link, type LinkProps } from "@tanstack/react-router";
import { Check } from "lucide-react";

/**
 * The light home's handful of shapes (styles/airy.css scopes the tokens).
 * Hand-rolled like every marketing page — never shadcn. Ink is the primary
 * colour; the product's purple → blue only ever appears as a small accent.
 */

export function AirContainer({ className = "", children }: { className?: string; children: ReactNode }) {
  return <div className={`mx-auto w-full max-w-6xl px-6 ${className}`}>{children}</div>;
}

/** Small label pill above a section or a feature row. */
export function AirPill({ icon, children, dark = false }: { icon?: ReactNode; children: ReactNode; dark?: boolean }) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-[12.5px] font-medium ${
        dark
          ? "bg-white/[0.08] text-white/80 ring-1 ring-white/12"
          : "bg-white text-[var(--cc-air-ink-2)] shadow-[0_1px_2px_rgb(0_0_0/0.06)] ring-1 ring-black/[0.07]"
      }`}
    >
      {icon ? <span className={dark ? "text-white/70" : "text-[var(--cc-air-violet)]"}>{icon}</span> : null}
      {children}
    </span>
  );
}

export function AirTitle({
  children,
  muted,
  className = "",
  as: Tag = "h2",
  dark = false,
}: {
  children: ReactNode;
  /** Trailing sentence in the muted colour. */
  muted?: ReactNode;
  className?: string;
  as?: "h1" | "h2" | "h3";
  dark?: boolean;
}) {
  return (
    <Tag
      className={`text-balance text-4xl font-semibold leading-[1.06] tracking-[-0.035em] md:text-[52px] ${
        dark ? "text-white" : "text-[var(--cc-air-ink)]"
      } ${className}`}
    >
      {children}
      {muted ? (
        <span className={dark ? "text-white/45" : "text-[var(--cc-air-faint)]"}> {muted}</span>
      ) : null}
    </Tag>
  );
}

export function AirLede({ children, className = "", dark = false }: { children: ReactNode; className?: string; dark?: boolean }) {
  return (
    <p
      className={`text-pretty text-[17px] leading-relaxed md:text-lg ${
        dark ? "text-white/62" : "text-[var(--cc-air-muted)]"
      } ${className}`}
    >
      {children}
    </p>
  );
}

export function AirChecks({ items, dark = false }: { items: string[]; dark?: boolean }) {
  return (
    <ul className="mt-6 space-y-2.5">
      {items.map((item) => (
        <li key={item} className={`flex gap-2.5 text-[15px] leading-snug ${dark ? "text-white/75" : "text-[var(--cc-air-ink-2)]"}`}>
          <span
            className={`mt-[1px] inline-flex h-[18px] w-[18px] shrink-0 items-center justify-center rounded-full ${
              dark ? "bg-white/12 text-white" : "bg-[var(--cc-air-ink)] text-white"
            }`}
          >
            <Check className="h-3 w-3" strokeWidth={3} />
          </span>
          {item}
        </li>
      ))}
    </ul>
  );
}

const BUTTON = "inline-flex h-11 items-center justify-center gap-2 rounded-full px-5 text-[15px] font-medium transition-[transform,box-shadow,background-color] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] hover:-translate-y-px active:translate-y-0 active:scale-[0.98]";

/** Ink pill — the page's primary action. `light` flips it for dark grounds. */
export function InkLink({
  light = false,
  className = "",
  children,
  ...props
}: LinkProps & { light?: boolean; className?: string; children: ReactNode }) {
  return (
    <Link
      {...props}
      className={`${BUTTON} ${
        light
          ? "bg-white text-[var(--cc-air-ink)] shadow-[0_8px_24px_-10px_rgb(0_0_0/0.5)] hover:shadow-[0_12px_30px_-10px_rgb(0_0_0/0.55)]"
          : INK
      } ${className}`}
    >
      {children}
    </Link>
  );
}

const INK = "bg-[var(--cc-air-ink)] text-white shadow-[inset_0_1px_0_rgb(255_255_255/0.14),0_8px_20px_-10px_rgb(0_0_0/0.55)] hover:bg-[#1b1b22]";
const SOFT = "bg-white text-[var(--cc-air-ink)] shadow-[0_1px_2px_rgb(0_0_0/0.06)] ring-1 ring-black/[0.08] hover:shadow-[0_6px_18px_-8px_rgb(0_0_0/0.2)]";

/** The ink pill as a plain anchor (downloads, external links). */
export function InkAnchor({ className = "", children, ...props }: React.AnchorHTMLAttributes<HTMLAnchorElement> & { children: ReactNode }) {
  return (
    <a {...props} className={`${BUTTON} ${INK} ${className}`}>
      {children}
    </a>
  );
}

/** The outlined pill on a dark band. */
export const GHOST_ON_DARK =
  "inline-flex h-11 items-center justify-center gap-2 rounded-full px-5 text-[15px] font-medium text-white/85 ring-1 ring-white/20 transition-colors hover:bg-white/[0.06] hover:text-white";

/** Quiet pill: white on the page, frosted glass on the dusk sky. */
export function SoftAnchor({ href, glass = false, children }: { href: string; glass?: boolean; children: ReactNode }) {
  return (
    <a
      href={href}
      className={`${BUTTON} ${glass ? "bg-white/14 text-white ring-1 ring-white/30 backdrop-blur-xl hover:bg-white/20" : SOFT}`}
    >
      {children}
    </a>
  );
}

/** The quiet pill as a router link. */
export function SoftLink({ className = "", children, ...props }: LinkProps & { className?: string; children: ReactNode }) {
  return (
    <Link {...props} className={`${BUTTON} ${SOFT} ${className}`}>
      {children}
    </Link>
  );
}

/** Compact section heading for the inner pages (AirTitle is the showpiece size). */
export function AirHeading({ children, muted, className = "", as: Tag = "h2" }: { children: ReactNode; muted?: ReactNode; className?: string; as?: "h2" | "h3" }) {
  return (
    <Tag className={`text-balance text-[26px] font-semibold leading-[1.15] tracking-[-0.03em] text-[var(--cc-air-ink)] md:text-[32px] ${className}`}>
      {children}
      {muted ? <span className="text-[var(--cc-air-faint)]"> {muted}</span> : null}
    </Tag>
  );
}

/** White card on the page: the FAQ and detail-card surface. */
export const AIR_CARD =
  "rounded-[24px] bg-white shadow-[0_1px_2px_rgb(0_0_0/0.04),0_24px_60px_-40px_rgb(30_20_90/0.35)] ring-1 ring-black/[0.06]";

export function AirCard({ children, className = "", as: Tag = "div" }: { children: ReactNode; className?: string; as?: "div" | "article" | "li" }) {
  return <Tag className={`${AIR_CARD} ${className}`}>{children}</Tag>;
}

/** Hairline grid (the home's toolbox): cells draw the right and bottom rules. */
export const AIR_GRID = "grid grid-cols-1 border-l border-t border-[var(--cc-air-hairline)]";
export const AIR_CELL = "border-b border-r border-[var(--cc-air-hairline)]";
/** A hairline cell that is a link: tints on hover. */
export const AIR_CELL_LINK = `${AIR_CELL} group p-6 transition-colors hover:bg-[var(--cc-air-tint)] md:p-7`;

/** Small white link pill (lists of related pages). */
export const AIR_CHIP =
  "inline-flex h-9 items-center rounded-full bg-white px-4 text-[13px] font-medium text-[var(--cc-air-ink-2)] shadow-[0_1px_2px_rgb(0_0_0/0.05)] ring-1 ring-black/[0.07] transition-[box-shadow,color] hover:text-[var(--cc-air-ink)] hover:shadow-[0_6px_18px_-8px_rgb(0_0_0/0.2)]";

/** White bezel on a coloured halo, for every product recreation. */
export function SoftFrame({ children, className = "", halo = true }: { children: ReactNode; className?: string; halo?: boolean }) {
  return (
    <div className={`${halo ? "air-halo" : ""} ${className}`}>
      <div className="air-frame">{children}</div>
    </div>
  );
}
