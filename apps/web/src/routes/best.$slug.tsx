import { Link, createFileRoute, notFound } from "@tanstack/react-router";
import { jsonLd } from "@/lib/json-ld";

import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
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
import { markdownAlternateLinks } from "@/lib/site-content";

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
    if (!list) return {};
    return {
      meta: [
        { title: `${list.title} (${FACTS_CHECKED.slice(0, 4)}) | CaptureCat` },
        { name: "description", content: list.description },
      ],
      links: markdownAlternateLinks(bestPath(list)),
    };
  },
  component: BestPage,
});

function Cell({ cell }: { cell: FeatureCell }) {
  if (cell === true) return <span className="text-foreground">✓</span>;
  if (cell === false) return <span className="text-muted-foreground/60">No</span>;
  if (cell === null)
    return <span className="text-xs text-muted-foreground/60">check their site</span>;
  return <span className="text-[13px] text-muted-foreground">{cell}</span>;
}

const card =
  "relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-6 backdrop-blur-2xl";

function Hairline() {
  return (
    <span
      aria-hidden
      className="absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
    />
  );
}

function BestPage() {
  const { slug } = Route.useLoaderData();
  const list = findBestList(slug)!;
  const entries = bestEntries(list);
  const rows = bestTableRows(list);
  const top = entries.slice(0, 3).map((e) => e.name);

  return (
    <main className="min-h-screen bg-background flex flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(bestJsonLd(list)) }}
      />
      <Navbar />

      <section className="relative isolate overflow-hidden">
        <div
          aria-hidden
          className="pointer-events-none absolute inset-0 -z-10"
          style={{
            background:
              "radial-gradient(120% 80% at 50% -20%, rgba(120,140,255,0.18), transparent 60%)," +
              "radial-gradient(70% 50% at 85% 20%, rgba(80,220,255,0.10), transparent 55%)",
          }}
        />
        <div className="mx-auto max-w-3xl px-6 pb-10 pt-20 md:pt-28">
          <Link
            to="/compare"
            className="text-sm font-medium uppercase tracking-[0.14em] text-muted-foreground transition-colors hover:text-foreground"
          >
            Compare
          </Link>
          <h1 className="mt-3 text-balance text-4xl font-semibold leading-[1.08] tracking-[-0.03em] md:text-5xl">
            {list.title} ({FACTS_CHECKED.slice(0, 4)})
          </h1>
          <p className="mt-6 text-pretty text-lg leading-relaxed text-muted-foreground">
            {list.intro}
          </p>
          <div className={`mt-8 ${card}`}>
            <Hairline />
            <p className="text-xs font-medium uppercase tracking-[0.14em] text-muted-foreground">
              Short answer
            </p>
            <p className="mt-3 text-lg leading-relaxed">
              {top.join(", ")}. {entries.length} tools qualified; the full table is below.
            </p>
          </div>
        </div>
      </section>

      <section className="mx-auto w-full max-w-3xl px-6 pb-8">
        <h2 className="text-2xl font-semibold tracking-[-0.02em]">How we picked</h2>
        <p className="mt-3 text-pretty text-sm leading-relaxed text-muted-foreground">
          {list.criteriaText} Facts checked {FACTS_CHECKED}. {DISCLOSURE}
        </p>
      </section>

      <section className="mx-auto w-full max-w-6xl px-6 py-8">
        <h2 className="text-2xl font-semibold tracking-[-0.02em]">At a glance</h2>
        <div className="relative mt-6 overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] backdrop-blur-2xl">
          <Hairline />
          <div className="overflow-x-auto">
            <table className="w-full min-w-[820px] text-left text-sm">
              <thead>
                <tr className="border-b border-white/10">
                  <th className="px-5 py-4 font-medium text-muted-foreground">#</th>
                  <th className="px-5 py-4 font-medium text-muted-foreground">Recorder</th>
                  {rows.map((r) => (
                    <th key={r} className="px-4 py-4 font-medium text-muted-foreground">
                      {FEATURE_ROWS[r].short}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {entries.map((e, i) => (
                  <tr
                    key={e.name}
                    className={`border-b border-white/5 last:border-0 ${e.competitor ? "" : "bg-white/[0.03]"}`}
                  >
                    <td className="px-5 py-3.5 tabular-nums text-muted-foreground">{i + 1}</td>
                    <th className="px-5 py-3.5 font-medium">
                      {e.competitor ? (
                        <Link
                          to="/compare/$slug"
                          params={{ slug: comparePath(e.competitor).split("/").pop()! }}
                          className="underline decoration-white/15 underline-offset-4 hover:decoration-white/50"
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
      </section>

      <section className="mx-auto w-full max-w-3xl px-6 py-8">
        <ol className="space-y-4">
          {entries.map((e, i) => (
            <li key={e.name} className={card}>
              <Hairline />
              <h2 className="text-lg font-semibold tracking-[-0.01em]">
                <span className="mr-2 tabular-nums text-muted-foreground">{i + 1}.</span>
                {e.name}
              </h2>
              <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{e.note}</p>
              {e.competitor && (
                <Link
                  to="/compare/$slug"
                  params={{ slug: comparePath(e.competitor).split("/").pop()! }}
                  className="mt-3 inline-block text-sm font-medium text-foreground underline decoration-white/20 underline-offset-4 hover:decoration-white/60"
                >
                  CaptureCat vs {e.name}
                </Link>
              )}
            </li>
          ))}
        </ol>
      </section>

      <PseoCta />
      <Footer />
    </main>
  );
}
