import { Link, createFileRoute, notFound } from "@tanstack/react-router";
import { jsonLd } from "@/lib/json-ld";

import Navbar from "@/components/landing/Navbar";
import Footer from "@/components/landing/Footer";
import {
  FeatureTable,
  StrengthsTradeoffs,
  FaqSection,
  PseoCta,
} from "@/components/landing/PseoSections";
import { COMPETITORS, buildPseoPage, pseoJsonLd } from "@/lib/pseo-content";
import { markdownAlternateLinks } from "@/lib/site-content";

/**
 * /alternatives/{competitor}-alternative — generated "X alternative" pages.
 * Content, Markdown twin, and JSON-LD all come from lib/pseo-content.ts.
 */

function competitorFromSlug(slug: string) {
  return COMPETITORS.find((c) => `${c.slug}-alternative` === slug);
}

export const Route = createFileRoute("/alternatives/$slug")({
  loader: async ({ params }) => {
    const competitor = competitorFromSlug(params.slug);
    if (!competitor) throw notFound();
    return { competitor };
  },
  head: ({ params }) => {
    const competitor = competitorFromSlug(params.slug);
    if (!competitor) return {};
    const page = buildPseoPage("alternative", competitor);
    return {
      meta: [
        { title: `${page.title} | CaptureCat` },
        { name: "description", content: page.description },
      ],
      links: markdownAlternateLinks(page.path),
    };
  },
  component: AlternativePage,
});

function AlternativePage() {
  const { competitor } = Route.useLoaderData();
  const page = buildPseoPage("alternative", competitor);

  return (
    <main className="min-h-screen bg-background flex flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(pseoJsonLd(page)) }}
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
          <p className="text-sm font-medium uppercase tracking-[0.14em] text-muted-foreground">
            {competitor.name} alternative
          </p>
          <h1 className="mx-auto mt-3 max-w-3xl text-balance text-5xl font-semibold leading-[1.04] tracking-[-0.03em] md:text-6xl">
            {page.heroTitle}
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-pretty text-lg leading-relaxed text-muted-foreground">
            {page.heroSubtitle}
          </p>
        </div>
      </section>

      <section className="mx-auto w-full max-w-6xl px-6 pb-8">
        <h2 className="text-2xl font-semibold tracking-[-0.02em]">
          CaptureCat vs {competitor.name} at a glance
        </h2>
        <div className="mt-6">
          <FeatureTable competitor={competitor} />
        </div>
        <p className="mt-4 text-sm text-muted-foreground">
          Want the long version?{" "}
          <Link
            to="/compare/$slug"
            params={{ slug: `capturecat-vs-${competitor.slug}` }}
            className="underline decoration-white/20 underline-offset-2 hover:text-foreground"
          >
            Read the full CaptureCat vs {competitor.name} comparison
          </Link>
          .
        </p>
      </section>

      <section className="mx-auto w-full max-w-6xl px-6 py-10">
        <StrengthsTradeoffs competitor={competitor} />
      </section>

      <FaqSection faqs={page.faqs} />
      <PseoCta competitorName={competitor.name} />

      <Footer />
    </main>
  );
}
