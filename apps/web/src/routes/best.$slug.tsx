import { Link, createFileRoute, notFound } from "@tanstack/react-router";
import { Check } from "lucide-react";
import { jsonLd } from "@/lib/json-ld";

import { PseoCta } from "@/components/marketing/PseoSections";
import {
  DISCLOSURE,
  bestEntries,
  bestJsonLd,
  bestPath,
  bestTableRows,
  findBestList,
} from "@/lib/best-content";
import { FACTS_CHECKED, FEATURE_ROWS, comparePath, type FeatureCell } from "@/lib/pseo-content";
import { pageHead } from "@/lib/site-content";
import { AirPage, AirPageHero, BackPill } from "@/components/marketing/airy/Page";
import { AIR_CARD, AirCard, AirContainer, AirHeading } from "@/components/marketing/airy/primitives";
import airyCss from "@/styles/airy.css?url";

/**
 * /best/{slug}: "best X" lists generated from the sourced competitor records.
 * Content, Markdown twin, and JSON-LD come from lib/best-content.ts.
 */

export const Route = createFileRoute("/best/$slug")({
  loader: async ({ params }) => {
    const list = findBestList(params.slug);
    if (!list) throw notFound();
    return { slug: list.slug };
  },
  head: ({ params }) => {
    const list = findBestList(params.slug);
    return list ? pageHead(bestPath(list), [{ rel: "stylesheet", href: airyCss }]) : {};
  },
  component: BestPage,
});

function Cell({ cell }: { cell: FeatureCell }) {
  if (cell === true)
    return (
      <span className="inline-flex h-5 w-5 items-center justify-center rounded-full bg-black/[0.06] text-[var(--cc-air-ink)]" aria-label="Yes">
        <Check className="h-3 w-3" strokeWidth={3} />
      </span>
    );
  if (cell === false) return <span className="text-[var(--cc-air-faint)]">No</span>;
  if (cell === null) return <span className="text-xs text-[var(--cc-air-faint)]">check their site</span>;
  return <span className="text-[13px] text-[var(--cc-air-muted)]">{cell}</span>;
}

function BestPage() {
  const { slug } = Route.useLoaderData();
  const list = findBestList(slug)!;
  const entries = bestEntries(list);
  const rows = bestTableRows(list);
  const top = entries.slice(0, 3).map((e) => e.name);

  return (
    <AirPage>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(bestJsonLd(list)) }}
      />
      <AirPageHero
        before={<BackPill to="/compare">Compare</BackPill>}
        align="left"
        compact
        title={`${list.title} (${FACTS_CHECKED.slice(0, 4)})`}
        lede={list.intro}
        className="!max-w-3xl md:!pb-14"
      >
        <AirCard className="mt-8 p-6 md:p-7">
          <p className="text-xs font-medium uppercase tracking-[0.12em] text-[var(--cc-air-faint)]">Short answer</p>
          <p className="mt-3 text-[18px] leading-relaxed text-[var(--cc-air-ink)]">
            {top.join(", ")}. {entries.length} tools qualified; the full table is below.
          </p>
        </AirCard>
      </AirPageHero>

      <AirContainer className="!max-w-3xl pb-8">
        <AirHeading>How we picked</AirHeading>
        <p className="mt-3 text-pretty text-[15px] leading-relaxed text-[var(--cc-air-muted)]">
          {list.criteriaText} Facts checked {FACTS_CHECKED}. {DISCLOSURE}
        </p>
      </AirContainer>

      <AirContainer className="py-8">
        <AirHeading>At a glance</AirHeading>
        <div className={`${AIR_CARD} mt-6 overflow-hidden`}>
          <div className="overflow-x-auto">
            <table className="w-full min-w-[820px] text-left text-sm">
              <thead>
                <tr className="border-b border-[var(--cc-air-hairline)] bg-[var(--cc-air-tint)]">
                  <th className="px-5 py-4 font-medium text-[var(--cc-air-muted)]">#</th>
                  <th className="px-5 py-4 font-medium text-[var(--cc-air-muted)]">Recorder</th>
                  {rows.map((r) => (
                    <th key={r} className="px-4 py-4 font-medium text-[var(--cc-air-muted)]">
                      {FEATURE_ROWS[r].short}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {entries.map((e, i) => (
                  <tr
                    key={e.name}
                    className={`border-b border-[var(--cc-air-hairline)] last:border-0 ${e.competitor ? "" : "bg-[#f7f5fe]"}`}
                  >
                    <td className="px-5 py-3.5 tabular-nums text-[var(--cc-air-faint)]">{i + 1}</td>
                    <th className="px-5 py-3.5 font-medium text-[var(--cc-air-ink)]">
                      {e.competitor ? (
                        <Link
                          to="/compare/$slug"
                          params={{ slug: comparePath(e.competitor).split("/").pop()! }}
                          className="underline decoration-black/15 underline-offset-4 hover:decoration-black/50"
                        >
                          {e.name}
                        </Link>
                      ) : (
                        <span className="font-semibold">CaptureCat</span>
                      )}
                    </th>
                    {rows.map((r) => (
                      <td key={r} className="px-4 py-3.5 align-top">
                        <Cell cell={e.cells[r]} />
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </AirContainer>

      <AirContainer className="!max-w-3xl py-8">
        <ol className="space-y-4">
          {entries.map((e, i) => (
            <AirCard key={e.name} as="li" className="p-6 md:p-7">
              <h2 className="text-[18px] font-semibold tracking-[-0.015em] text-[var(--cc-air-ink)]">
                <span className="mr-2 tabular-nums text-[var(--cc-air-faint)]">{i + 1}.</span>
                {e.name}
              </h2>
              <p className="mt-2 text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">{e.note}</p>
              {e.competitor && (
                <Link
                  to="/compare/$slug"
                  params={{ slug: comparePath(e.competitor).split("/").pop()! }}
                  className="mt-3 inline-block text-[14px] font-medium text-[var(--cc-air-ink)] underline decoration-black/20 underline-offset-4 hover:decoration-black/60"
                >
                  CaptureCat vs {e.name}
                </Link>
              )}
            </AirCard>
          ))}
        </ol>
      </AirContainer>

      <PseoCta />
    </AirPage>
  );
}
