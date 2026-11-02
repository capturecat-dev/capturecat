import { Link } from "@tanstack/react-router";
import { Check } from "lucide-react";

import {
  COMPETITORS,
  FEATURE_ROWS,
  comparePath,
  cellText,
  type Competitor,
  type Faq,
  type FeatureCell,
  FACTS_CHECKED,
} from "@/lib/pseo-content";
import { AirFaq } from "./airy/Faq";
import { AIR_CARD } from "./airy/primitives";
import { AppleGlyph } from "./primitives";

/**
 * Presentational sections shared by the /compare, /alternatives, /best and
 * /guides pages, in the light home's language (airy/primitives.tsx). The CTA
 * is also on the dark docs pages, so it spells its colours out instead of
 * reading the light tokens.
 */

const LINK = "underline decoration-black/20 underline-offset-2 hover:text-[var(--cc-air-ink)] hover:decoration-black/50";
const TABLE_WRAP = `${AIR_CARD} relative overflow-hidden`;

function Cell({ cell, highlight }: { cell: FeatureCell; highlight?: boolean }) {
  if (cell === true)
    return (
      <span
        className={`inline-flex h-5 w-5 items-center justify-center rounded-full ${
          highlight ? "bg-[var(--cc-air-ink)] text-white" : "bg-black/[0.06] text-[var(--cc-air-ink)]"
        }`}
        aria-label="Yes"
      >
        <Check className="h-3 w-3" strokeWidth={3} />
      </span>
    );
  if (cell === false) return <span className="text-[var(--cc-air-faint)]">No</span>;
  if (cell === null) return <span className="text-xs text-[var(--cc-air-faint)]">check their site</span>;
  return <span className="text-[13px] text-[var(--cc-air-muted)]">{cell}</span>;
}

export function FeatureTable({ competitor }: { competitor: Competitor }) {
  return (
    <div className={TABLE_WRAP}>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[560px] text-left text-sm">
          <thead>
            <tr className="border-b border-[var(--cc-air-hairline)] bg-[var(--cc-air-tint)]">
              <th className="px-6 py-4 font-medium text-[var(--cc-air-muted)]">Feature</th>
              <th className="bg-[rgb(124_92_240/0.06)] px-6 py-4 font-semibold text-[var(--cc-air-ink)]">CaptureCat</th>
              <th className="px-6 py-4 font-medium text-[var(--cc-air-muted)]">{competitor.name}</th>
            </tr>
          </thead>
          <tbody>
            {FEATURE_ROWS.map((row, i) => (
              <tr key={row.label} className="border-b border-[var(--cc-air-hairline)] last:border-0">
                <td className="px-6 py-3.5 text-[var(--cc-air-ink-2)]">{row.label}</td>
                <td className="bg-[rgb(124_92_240/0.04)] px-6 py-3.5">
                  <Cell cell={row.capturecat} highlight />
                </td>
                <td className="px-6 py-3.5">
                  <Cell cell={competitor.features[i]} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="border-t border-[var(--cc-air-hairline)] px-6 py-4 text-xs leading-relaxed text-[var(--cc-air-faint)]">
        Competitor details checked {FACTS_CHECKED}. See{" "}
        <a href={competitor.website} rel="nofollow noopener" className={LINK}>
          {competitor.name}&apos;s site
        </a>{" "}
        for current pricing and features. Sources:{" "}
        {competitor.sources.map((url, i) => (
          <span key={url}>
            {i > 0 && ", "}
            <a href={url} rel="nofollow noopener" className={LINK}>
              {new URL(url).hostname.replace(/^www\./, "")}
              {new URL(url).pathname === "/" ? "" : new URL(url).pathname}
            </a>
          </span>
        ))}
        .
      </p>
    </div>
  );
}

/**
 * Every recorder against every row, for the /compare hub. The first column
 * stays put while the rest scroll sideways on narrow screens.
 */
export function CompareMatrix() {
  return (
    <div className={TABLE_WRAP}>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[1100px] text-left text-sm">
          <thead>
            <tr className="border-b border-[var(--cc-air-hairline)] bg-[var(--cc-air-tint)]">
              <th className="sticky left-0 z-10 bg-[var(--cc-air-tint)] px-5 py-4 font-medium text-[var(--cc-air-muted)]">
                Recorder
              </th>
              {FEATURE_ROWS.map((row) => (
                <th key={row.short} className="px-4 py-4 font-medium text-[var(--cc-air-muted)]">
                  {row.short}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            <tr className="border-b border-[var(--cc-air-hairline)] bg-[#f7f5fe]">
              <th className="sticky left-0 z-10 bg-[#f7f5fe] px-5 py-3.5 font-semibold text-[var(--cc-air-ink)]">
                CaptureCat
              </th>
              {FEATURE_ROWS.map((row) => (
                <td key={row.short} className="px-4 py-3.5 align-top">
                  <Cell cell={row.capturecat} highlight />
                </td>
              ))}
            </tr>
            {COMPETITORS.map((c) => (
              <tr key={c.slug} className="border-b border-[var(--cc-air-hairline)] last:border-0">
                <th className="sticky left-0 z-10 bg-white px-5 py-3.5 font-medium">
                  <Link
                    to="/compare/$slug"
                    params={{ slug: comparePath(c).split("/").pop()! }}
                    className="text-[var(--cc-air-ink)] underline decoration-black/15 underline-offset-4 hover:decoration-black/50"
                  >
                    {c.name}
                  </Link>
                </th>
                {c.features.map((cell, i) => (
                  <td key={FEATURE_ROWS[i].short} className="px-4 py-3.5 align-top">
                    <Cell cell={cell} />
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="border-t border-[var(--cc-air-hairline)] px-6 py-4 text-xs leading-relaxed text-[var(--cc-air-faint)]">
        Checked against each product&apos;s own site on {FACTS_CHECKED}. &ldquo;check their
        site&rdquo; means we could not verify it either way. Each comparison page lists its sources.
      </p>
    </div>
  );
}

export function StrengthsTradeoffs({ competitor }: { competitor: Competitor }) {
  const columns = [
    { title: `Where ${competitor.name} shines`, items: competitor.strengths },
    { title: "Trade-offs", items: competitor.tradeoffs },
  ];
  return (
    <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
      {columns.map((col) => (
        <article key={col.title} className={`${AIR_CARD} p-7`}>
          <h3 className="text-[17px] font-semibold tracking-[-0.015em] text-[var(--cc-air-ink)]">{col.title}</h3>
          <ul className="mt-4 space-y-2.5">
            {col.items.map((item) => (
              <li key={item} className="flex gap-2.5 text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">
                <span aria-hidden className="mt-[9px] h-1 w-1 shrink-0 rounded-full bg-[var(--cc-air-violet)]" />
                {item}
              </li>
            ))}
          </ul>
        </article>
      ))}
    </div>
  );
}

export function FaqSection({ faqs }: { faqs: Faq[] }) {
  return <AirFaq items={faqs.map((f) => ({ q: f.question, a: f.answer }))} title="FAQ" />;
}

const CTA_GHOST =
  "inline-flex h-11 items-center justify-center rounded-full px-5 text-[15px] font-medium text-white/85 ring-1 ring-white/20 transition-colors hover:bg-white/[0.06] hover:text-white";

/** The dark closing card. Explicit colours: the docs pages (dark) share it. */
export function PseoCta({ competitorName }: { competitorName?: string }) {
  return (
    <section className="mx-auto w-full max-w-6xl px-6 py-20">
      <div
        data-air-dark
        className="relative isolate overflow-hidden rounded-[32px] bg-[#0b0b10] px-8 py-14 text-center text-white ring-1 ring-white/10 md:px-12 md:py-16"
      >
        <div
          aria-hidden
          className="absolute inset-0 -z-10 bg-[radial-gradient(55%_70%_at_50%_0%,rgb(124_92_240/0.4),transparent_70%),radial-gradient(40%_50%_at_50%_100%,rgb(255_150_120/0.16),transparent_70%)]"
        />
        <h2 className="text-balance text-[28px] font-semibold leading-[1.1] tracking-[-0.03em] text-white md:text-[40px]">
          Try the recording{competitorName ? `, not the pitch` : ""}
        </h2>
        <p className="mx-auto mt-4 max-w-xl text-pretty text-[15.5px] leading-relaxed text-white/62">
          The recorder and the full editor are free for personal use. Record
          one clip and watch the zooms, cursor smoothing, and captions appear
          on their own.
        </p>
        <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
          <Link
            to="/download"
            className="inline-flex h-11 items-center justify-center gap-2 rounded-full bg-white px-5 text-[15px] font-medium text-[#0b0b0f] shadow-[0_8px_24px_-10px_rgb(0_0_0/0.5)] transition-transform duration-300 hover:-translate-y-px active:translate-y-0 active:scale-[0.98]"
          >
            <AppleGlyph />
            Download for Mac
          </Link>
          <Link to="/pricing" className={CTA_GHOST}>
            Pricing
          </Link>
          <Link to="/compare" className={CTA_GHOST}>
            All comparisons
          </Link>
        </div>
      </div>
    </section>
  );
}
