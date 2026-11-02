import type { ReactNode } from "react";
import { Link, type LinkProps } from "@tanstack/react-router";
import { ArrowLeft } from "lucide-react";

import Navbar from "../Navbar";
import Footer from "../Footer";
import { AirContainer, AirLede, AirPill, AirTitle } from "./primitives";

/**
 * The light shell every marketing page shares with the home: `data-cc-light`
 * re-points the theme tokens (styles/airy.css, which the route must also add
 * to its head links), the nav pill floats on top, the footer closes it.
 */
export function AirPage({ children }: { children: ReactNode }) {
  return (
    <main data-cc-light className="flex min-h-screen flex-col bg-background text-foreground selection:bg-violet-500/20">
      <Navbar />
      {children}
      <Footer />
    </main>
  );
}

/**
 * An inner page's opening: the dusk sky's colours as a pale wash under ink
 * type, so the home keeps the only full sky. Pulled up under the nav pill
 * like the home hero.
 */
export function AirPageHero({
  pill,
  icon,
  title,
  muted,
  lede,
  before,
  align = "center",
  compact = false,
  className = "",
  children,
}: {
  pill?: ReactNode;
  icon?: ReactNode;
  title: ReactNode;
  /** Trailing sentence of the title, in the faint colour. */
  muted?: ReactNode;
  lede?: ReactNode;
  /** Above the title in place of the pill (a BackPill). */
  before?: ReactNode;
  align?: "center" | "left";
  /** A smaller title, for long question and list titles. */
  compact?: boolean;
  /** Extra container classes (width, bottom padding). */
  className?: string;
  children?: ReactNode;
}) {
  const center = align === "center";
  return (
    <section className="relative isolate -mt-[68px] overflow-hidden">
      <div className="air-wash" aria-hidden />
      <AirContainer
        className={`pb-14 pt-[132px] md:pb-20 md:pt-[168px] ${center ? "flex flex-col items-center text-center" : ""} ${className}`}
      >
        {before}
        {pill ? <AirPill icon={icon}>{pill}</AirPill> : null}
        <AirTitle
          as="h1"
          muted={muted}
          className={`max-w-3xl ${compact ? "md:!text-[46px]" : "md:!text-[60px]"} ${pill || before ? "mt-5" : ""}`}
        >
          {title}
        </AirTitle>
        {lede ? <AirLede className="mt-5 max-w-2xl">{lede}</AirLede> : null}
        {children}
      </AirContainer>
    </section>
  );
}

/** The pill above a detail page's title, back to its hub. */
export function BackPill({ children, ...props }: LinkProps & { children: ReactNode }) {
  return (
    <Link
      {...props}
      className="group inline-flex items-center gap-1.5 rounded-full bg-white px-3 py-1 text-[12.5px] font-medium text-[var(--cc-air-ink-2)] shadow-[0_1px_2px_rgb(0_0_0/0.06)] ring-1 ring-black/[0.07] transition-shadow hover:shadow-[0_6px_18px_-8px_rgb(0_0_0/0.2)]"
    >
      <ArrowLeft className="h-3.5 w-3.5 text-[var(--cc-air-violet)] transition-transform group-hover:-translate-x-0.5" strokeWidth={2} />
      {children}
    </Link>
  );
}
