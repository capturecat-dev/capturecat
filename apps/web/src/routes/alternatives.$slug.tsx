import { Link, createFileRoute, notFound } from "@tanstack/react-router";
import { Scale } from "lucide-react";
import { jsonLd } from "@/lib/json-ld";

import { ProductLoop } from "@/components/marketing/home/demo/ProductLoop";
import demosCss from "@/styles/demos.css?url";
import airyCss from "@/styles/airy.css?url";
import { AirPage, AirPageHero } from "@/components/marketing/airy/Page";
import { AirContainer, AirHeading, SoftFrame } from "@/components/marketing/airy/primitives";
import {
  FeatureTable,
  StrengthsTradeoffs,
  FaqSection,
  PseoCta,
} from "@/components/marketing/PseoSections";
import { COMPETITORS, alternativePath, buildPseoPage, pseoJsonLd } from "@/lib/pseo-content";
import { pageHead } from "@/lib/site-content";

/**
 * /alternatives/{competitor}-alternative: generated "X alternative" pages.
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
    return pageHead(alternativePath(competitor), [
      { rel: "stylesheet", href: demosCss },
      { rel: "stylesheet", href: airyCss },
    ]);
  },
  component: AlternativePage,
});

function AlternativePage() {
  const { competitor } = Route.useLoaderData();
  const page = buildPseoPage("alternative", competitor);

  return (
    <AirPage>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(pseoJsonLd(page)) }}
      />
      <AirPageHero
        pill={`${competitor.name} alternative`}
        icon={<Scale className="h-3.5 w-3.5" strokeWidth={2} />}
        title={page.heroTitle}
        lede={page.heroSubtitle}
      >
        <div className="mt-14 w-full max-w-4xl text-left">
          <SoftFrame>
            <ProductLoop />
          </SoftFrame>
        </div>
      </AirPageHero>

      <AirContainer className="pb-8 pt-6">
        <AirHeading>CaptureCat vs {competitor.name} at a glance</AirHeading>
        <div className="mt-6">
          <FeatureTable competitor={competitor} />
        </div>
        <p className="mt-4 text-[14.5px] text-[var(--cc-air-muted)]">
          Want the long version?{" "}
          <Link
            to="/compare/$slug"
            params={{ slug: `capturecat-vs-${competitor.slug}` }}
            className="font-medium text-[var(--cc-air-ink)] underline decoration-black/20 underline-offset-4 hover:decoration-black/60"
          >
            Read the full CaptureCat vs {competitor.name} comparison
          </Link>
          .
        </p>
      </AirContainer>

      <AirContainer className="pb-24 pt-10">
        <StrengthsTradeoffs competitor={competitor} />
      </AirContainer>

      <FaqSection faqs={page.faqs} />
      <PseoCta competitorName={competitor.name} />
    </AirPage>
  );
}
