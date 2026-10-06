import { Link } from "@tanstack/react-router";

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

/**
 * Presentational sections shared by the /compare and /alternatives pages.
 * Pure server components, same glass-card language as the agents page.
 */

function Cell({ cell, highlight }: { cell: FeatureCell; highlight?: boolean }) {
  if (cell === true)
    return (
      <span className={highlight ? "text-cyan-300" : "text-foreground"}>✓</span>
    );
  if (cell === false) return <span className="text-muted-foreground/60">No</span>;
  if (cell === null)
    return <span className="text-muted-foreground/60 text-xs">check their site</span>;
  return <span className="text-muted-foreground text-[13px]">{cell}</span>;
}

export function FeatureTable({ competitor }: { competitor: Competitor }) {
  return (
    <div className="relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] backdrop-blur-2xl">
      <span
        aria-hidden
        className="absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
      />
      <div className="overflow-x-auto">
        <table className="w-full min-w-[560px] text-left text-sm">
          <thead>
            <tr className="border-b border-white/10">
              <th className="px-6 py-4 font-medium text-muted-foreground">
                Feature
              </th>
              <th className="px-6 py-4 font-semibold text-foreground">
                CaptureCat
              </th>
              <th className="px-6 py-4 font-medium text-muted-foreground">
                {competitor.name}
              </th>
            </tr>
          </thead>
          <tbody>
            {FEATURE_ROWS.map((row, i) => (
              <tr key={row.label} className="border-b border-white/5 last:border-0">
                <td className="px-6 py-3.5 text-muted-foreground">{row.label}</td>
                <td className="px-6 py-3.5">
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
      <p className="px-6 py-4 text-xs text-muted-foreground/70">
        Competitor details checked {FACTS_CHECKED}. See{" "}
        <a
          href={competitor.website}
          rel="nofollow noopener"
          className="underline decoration-white/20 underline-offset-2 hover:text-foreground"
        >
          {competitor.name}&apos;s site
        </a>{" "}
        for current pricing and features. Sources:{" "}
        {competitor.sources.map((url, i) => (
          <span key={url}>
            {i > 0 && ", "}
            <a
              href={url}
              rel="nofollow noopener"
              className="underline decoration-white/20 underline-offset-2 hover:text-foreground"
            >
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
    <div className="relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] backdrop-blur-2xl">
      <span
        aria-hidden
        className="absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
      />
      <div className="overflow-x-auto">
        <table className="w-full min-w-[1100px] text-left text-sm">
          <thead>
            <tr className="border-b border-white/10">
              <th className="sticky left-0 z-10 bg-background/90 px-5 py-4 font-medium text-muted-foreground backdrop-blur">
                Recorder
              </th>
              {FEATURE_ROWS.map((row) => (
                <th key={row.short} className="px-4 py-4 font-medium text-muted-foreground">
                  {row.short}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            <tr className="border-b border-white/10 bg-white/[0.03]">
              <th className="sticky left-0 z-10 bg-background/90 px-5 py-3.5 font-semibold text-foreground backdrop-blur">
                CaptureCat
              </th>
              {FEATURE_ROWS.map((row) => (
                <td key={row.short} className="px-4 py-3.5 align-top">
                  <Cell cell={row.capturecat} highlight />
                </td>
              ))}
            </tr>
            {COMPETITORS.map((c) => (
              <tr key={c.slug} className="border-b border-white/5 last:border-0">
                <th className="sticky left-0 z-10 bg-background/90 px-5 py-3.5 font-medium backdrop-blur">
                  <Link
                    to="/compare/$slug"
                    params={{ slug: comparePath(c).split("/").pop()! }}
                    className="text-foreground underline decoration-white/15 underline-offset-4 hover:decoration-white/50"
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
      <p className="px-6 py-4 text-xs text-muted-foreground/70">
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
        <article
          key={col.title}
          className="relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-6 backdrop-blur-2xl"
        >
          <span
            aria-hidden
            className="absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
          />
          <h3 className="font-medium tracking-[-0.01em]">{col.title}</h3>
          <ul className="mt-3 space-y-2">
            {col.items.map((item) => (
              <li
                key={item}
                className="flex gap-2.5 text-sm leading-relaxed text-muted-foreground"
              >
                <span aria-hidden className="mt-2 h-1 w-1 shrink-0 rounded-full bg-white/40" />
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
  return (
    <section className="mx-auto w-full max-w-6xl px-6 py-16">
      <h2 className="text-2xl font-semibold tracking-[-0.02em]">FAQ</h2>
      <div className="mt-6 grid grid-cols-1 gap-4 lg:grid-cols-2">
        {faqs.map((faq) => (
          <article
            key={faq.question}
            className="relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-6 backdrop-blur-2xl"
          >
            <span
              aria-hidden
              className="absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
            />
            <h3 className="font-medium tracking-[-0.01em]">{faq.question}</h3>
            <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
              {faq.answer}
            </p>
          </article>
        ))}
      </div>
    </section>
  );
}

export function PseoCta({ competitorName }: { competitorName?: string }) {
  return (
    <section className="mx-auto w-full max-w-6xl px-6 pb-20">
      <div className="relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-8 text-center backdrop-blur-2xl md:p-12">
        <span
          aria-hidden
          className="absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
        />
        <h2 className="text-2xl font-semibold tracking-[-0.02em] md:text-3xl">
          Try the recording{competitorName ? `, not the pitch` : ""}
        </h2>
        <p className="mx-auto mt-3 max-w-xl text-sm leading-relaxed text-muted-foreground">
          The recorder and the full editor are free. Record one clip and watch
          the zooms, cursor smoothing, and captions appear on their own.
        </p>
        <div className="mt-6 flex flex-wrap items-center justify-center gap-3">
          <Link
            to="/download"
            className="inline-flex h-10 items-center justify-center rounded-full bg-white px-5 text-sm font-medium text-black transition-transform duration-300 hover:scale-[1.03] active:scale-[0.98]"
          >
            Download for Mac
          </Link>
          <Link
            to="/pricing"
            className="inline-flex h-10 items-center justify-center rounded-full border border-white/15 bg-white/[0.06] px-5 text-sm font-medium text-foreground transition-colors hover:bg-white/[0.1]"
          >
            Pricing
          </Link>
          <Link
            to="/compare"
            className="inline-flex h-10 items-center justify-center rounded-full border border-white/15 bg-white/[0.06] px-5 text-sm font-medium text-foreground transition-colors hover:bg-white/[0.1]"
          >
            All comparisons
          </Link>
        </div>
      </div>
    </section>
  );
}
