import type { ReactNode } from "react";
import { Link, type LinkProps } from "@tanstack/react-router";

/**
 * The handful of shapes every marketing page is built from. All of it is the
 * site's existing glass language: white/[0.05] surfaces, a specular hairline
 * across the top, and pill buttons. Marketing pages never use shadcn.
 */

export function Container({
  className = "",
  children,
}: {
  className?: string;
  children: ReactNode;
}) {
  return <div className={`mx-auto w-full max-w-6xl px-6 ${className}`}>{children}</div>;
}

export function Eyebrow({ children }: { children: ReactNode }) {
  return (
    <span className="inline-flex items-center gap-2 rounded-full border border-white/12 bg-white/[0.06] px-3.5 py-1.5 text-[12.5px] font-medium text-muted-foreground backdrop-blur-xl">
      <span className="h-1.5 w-1.5 rounded-full bg-cyan-300/80" />
      {children}
    </span>
  );
}

export function SectionTitle({
  children,
  muted,
  className = "",
  as: Tag = "h2",
}: {
  children: ReactNode;
  /** Trailing sentence rendered in the muted colour. */
  muted?: ReactNode;
  className?: string;
  as?: "h1" | "h2";
}) {
  return (
    <Tag
      className={`max-w-2xl text-balance text-4xl font-semibold tracking-[-0.03em] text-foreground md:text-5xl ${className}`}
    >
      {children}
      {muted ? <span className="text-muted-foreground"> {muted}</span> : null}
    </Tag>
  );
}

export function Lede({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <p className={`max-w-xl text-pretty text-lg leading-relaxed text-muted-foreground ${className}`}>
      {children}
    </p>
  );
}

export function GlassCard({
  children,
  className = "",
  spot = false,
  padding = "p-8",
}: {
  children: ReactNode;
  className?: string;
  /** Adds the cursor spotlight (needs a SpotlightGroup ancestor). */
  spot?: boolean;
  padding?: string;
}) {
  return (
    <article
      className={`relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] backdrop-blur-2xl ${
        spot
          ? "glass-spot group transition-colors duration-500 hover:border-white/20 hover:bg-white/[0.075]"
          : ""
      } ${padding} ${className}`}
    >
      <span
        aria-hidden
        className="absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
      />
      {children}
    </article>
  );
}

export function IconTile({ children }: { children: ReactNode }) {
  return (
    <div className="inline-flex h-11 w-11 items-center justify-center rounded-2xl border border-white/12 bg-white/[0.07] text-foreground shadow-[inset_0_1px_0_rgba(255,255,255,0.18)]">
      {children}
    </div>
  );
}

const primary =
  "group inline-flex h-12 items-center justify-center gap-2 rounded-full bg-white px-7 text-[15px] font-medium text-black shadow-[0_8px_30px_rgba(0,0,0,0.35)] transition-transform duration-300 hover:scale-[1.02] active:scale-[0.99]";
const secondary =
  "inline-flex h-12 items-center justify-center gap-2 rounded-full border border-white/12 bg-white/[0.06] px-7 text-[15px] font-medium text-foreground backdrop-blur-xl transition-colors duration-300 hover:border-white/20 hover:bg-white/[0.10]";

export function PrimaryLink({
  className = "",
  children,
  ...props
}: LinkProps & { className?: string; children: ReactNode }) {
  return (
    <Link {...props} className={`${primary} ${className}`}>
      {children}
    </Link>
  );
}

export function SecondaryLink({
  className = "",
  children,
  ...props
}: LinkProps & { className?: string; children: ReactNode }) {
  return (
    <Link {...props} className={`${secondary} ${className}`}>
      {children}
    </Link>
  );
}

export function PrimaryAnchor({
  className = "",
  children,
  ...props
}: React.AnchorHTMLAttributes<HTMLAnchorElement> & { children: ReactNode }) {
  return (
    <a {...props} className={`${primary} ${className}`}>
      {children}
    </a>
  );
}

export function SecondaryAnchor({
  className = "",
  children,
  ...props
}: React.AnchorHTMLAttributes<HTMLAnchorElement> & { children: ReactNode }) {
  return (
    <a {...props} className={`${secondary} ${className}`}>
      {children}
    </a>
  );
}

/** Public source repository. AGPL-3.0. */
export const GITHUB_URL = "https://github.com/capturecat-dev/capturecat";

export function GitHubIcon({ className = "h-[18px] w-[18px]" }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <path d="M12 .5C5.65.5.5 5.65.5 12c0 5.08 3.29 9.39 7.86 10.91.58.1.79-.25.79-.56v-2.17c-3.2.7-3.87-1.37-3.87-1.37-.52-1.33-1.28-1.68-1.28-1.68-1.04-.71.08-.7.08-.7 1.15.08 1.76 1.19 1.76 1.19 1.03 1.76 2.69 1.25 3.35.96.1-.75.4-1.25.73-1.54-2.55-.29-5.24-1.28-5.24-5.69 0-1.26.45-2.29 1.19-3.09-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.17 1.18a11 11 0 0 1 5.78 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.8 1.19 1.83 1.19 3.09 0 4.42-2.69 5.39-5.26 5.68.41.36.78 1.06.78 2.14v3.17c0 .31.21.67.8.56A11.51 11.51 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5z" />
    </svg>
  );
}

/** The Apple glyph used on download buttons. */
export function AppleGlyph({ className = "h-[18px] w-[18px]" }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 842.32 1000" fill="currentColor" aria-hidden>
      <path d="M824.66636 779.30363c-15.12299 34.93724-33.02368 67.09674-53.7638 96.66374-28.27076 40.3074-51.4182 68.2078-69.25717 83.7012-27.65347 25.4313-57.2822 38.4556-89.00964 39.1963-22.77708 0-50.24539-6.4813-82.21973-19.629-32.07926-13.0861-61.55985-19.5673-88.51583-19.5673-28.27075 0-58.59083 6.4812-91.02193 19.5673-32.48053 13.1477-58.64639 19.9994-78.65196 20.6784-30.42501 1.29623-60.75123-12.0985-91.02193-40.2457-19.32039-16.8514-43.48632-45.7394-72.43607-86.6641-31.060778-43.7024-56.597041-94.37983-76.602609-152.15586C10.740416 658.44309 0 598.01283 0 539.50845c0-67.01648 14.481044-124.8172 43.486336-173.25401C66.28194 327.34823 96.60818 296.6578 134.5638 274.1276c37.95566-22.53016 78.96676-34.01129 123.1321-34.74585 24.16591 0 55.85633 7.47508 95.23784 22.166 39.27042 14.74029 64.48571 22.21538 75.54091 22.21538 8.26518 0 36.27668-8.7405 83.7629-26.16587 44.90607-16.16001 82.80614-22.85118 113.85458-20.21546 84.13326 6.78992 147.34122 39.95559 189.37699 99.70686-75.24463 45.59122-112.46573 109.4473-111.72502 191.36456.67899 63.8067 23.82643 116.90384 69.31888 159.06309 20.61664 19.56727 43.64066 34.69027 69.2571 45.4307-5.55531 16.11062-11.41933 31.54225-17.65372 46.35662zM631.70926 20.0057c0 50.01141-18.27108 96.70693-54.6897 139.92782-43.94932 51.38118-97.10817 81.07162-154.75459 76.38659-.73454-5.99983-1.16045-12.31444-1.16045-18.95003 0-48.01091 20.9006-99.39207 58.01678-141.40314 18.53027-21.27094 42.09746-38.95744 70.67685-53.0663C578.3158 9.00229 605.2903 1.31621 630.65988 0c.74076 6.68575 1.04938 13.37191 1.04938 20.00505z" />
    </svg>
  );
}

/** Soft ambient light behind a section, so the glass has something to catch. */
export function Ambient({ variant = "top" }: { variant?: "top" | "bottom" | "hero" }) {
  const bg =
    variant === "hero"
      ? "radial-gradient(120% 80% at 50% -20%, rgba(120,140,255,0.22), transparent 60%)," +
        "radial-gradient(90% 60% at 85% 10%, rgba(80,220,255,0.14), transparent 55%)," +
        "radial-gradient(70% 50% at 10% 30%, rgba(190,120,255,0.12), transparent 60%)"
      : variant === "bottom"
        ? "radial-gradient(70% 50% at 50% 100%, rgba(80,220,255,0.08), transparent 65%)"
        : "radial-gradient(80% 50% at 50% 0%, rgba(120,140,255,0.10), transparent 65%)";
  return (
    <div aria-hidden className="pointer-events-none absolute inset-0 -z-10" style={{ background: bg }} />
  );
}
