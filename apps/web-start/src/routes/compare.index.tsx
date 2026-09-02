import { Link, createFileRoute } from "@tanstack/react-router";
import { jsonLd } from "@/lib/json-ld";

import Navbar from "@/components/landing/Navbar";
import Footer from "@/components/landing/Footer";
import { PseoCta } from "@/components/landing/PseoSections";
import {
  PSEO_COMPARE_PAGES,
  PSEO_ALTERNATIVE_PAGES,
  captureCatJsonLd,
} from "@/lib/pseo-content";
import { SITE_URL, markdownAlternateLinks } from "@/lib/site-content";

/**
 * /compare — the hub that links every generated comparison and alternative
 * page, so crawlers (and people) can reach all of them from one place.
 */

const jsonLdData = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "CollectionPage",
      "@id": `${SITE_URL}/compare`,
      name: "Compare Mac Screen Recorders",
      url: `${SITE_URL}/compare`,
      about: { "@id": `${SITE_URL}/#app` },
      mainEntity: { "@id": `${SITE_URL}/compare#list` },
    },
    {
      "@type": "ItemList",
      "@id": `${SITE_URL}/compare#list`,
      itemListElement: PSEO_COMPARE_PAGES.map((page, i) => ({
        "@type": "ListItem",
        position: i + 1,
        name: page.title,
        url: `${SITE_URL}${page.path}`,
      })),
    },
    captureCatJsonLd(),
  ],
};

export const Route = createFileRoute("/compare/")({
  head: () => ({
    meta: [
      { title: "Compare Mac Screen Recorders | CaptureCat" },
      {
        name: "description",
        content:
          "How CaptureCat compares to Screen Studio, Cap, Loom, CleanShot X, OBS, Camtasia, Kap, and QuickTime — features, pricing, and honest trade-offs.",
      },
    ],
    links: markdownAlternateLinks("/compare"),
  }),
  component: CompareHubPage,
});

function CompareHubPage() {
  return (
    <main className="min-h-screen bg-background flex flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(jsonLdData) }}
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
        <div className="mx-auto max-w-6xl px-6 pb-14 pt-20 text-center md:pt-28">
          <h1 className="mx-auto max-w-3xl text-balance text-5xl font-semibold leading-[1.04] tracking-[-0.03em] md:text-6xl">
            How CaptureCat compares
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-pretty text-lg leading-relaxed text-muted-foreground">
            Feature-by-feature comparisons with the other Mac screen recorders —
            including where each of them is genuinely the better pick.
          </p>
        </div>
      </section>

      <section className="mx-auto w-full max-w-6xl px-6 pb-8">
        <h2 className="text-2xl font-semibold tracking-[-0.02em]">Comparisons</h2>
        <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2">
          {PSEO_COMPARE_PAGES.map((page) => (
            <Link
              key={page.path}
              to="/compare/$slug"
              params={{ slug: page.path.split("/").pop()! }}
              className="group relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-6 backdrop-blur-2xl transition-colors hover:bg-white/[0.07]"
            >
              <span
                aria-hidden
                className="absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
              />
              <h3 className="font-medium tracking-[-0.01em] group-hover:text-foreground">
                {page.title}
              </h3>
              <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                {page.competitor.summary}
              </p>
            </Link>
          ))}
        </div>
      </section>

      <section className="mx-auto w-full max-w-6xl px-6 py-12">
        <h2 className="text-2xl font-semibold tracking-[-0.02em]">
          Looking for an alternative?
        </h2>
        <div className="mt-6 flex flex-wrap gap-3">
          {PSEO_ALTERNATIVE_PAGES.map((page) => (
            <Link
              key={page.path}
              to="/alternatives/$slug"
              params={{ slug: page.path.split("/").pop()! }}
              className="inline-flex h-9 items-center rounded-full border border-white/12 bg-white/[0.06] px-4 text-[13px] font-medium text-muted-foreground transition-colors hover:bg-white/[0.1] hover:text-foreground"
            >
              {page.title}
            </Link>
          ))}
        </div>
      </section>

      <PseoCta />

      <Footer />
    </main>
  );
}
