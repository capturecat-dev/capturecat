import { Link, createFileRoute } from "@tanstack/react-router";
import { Scale } from "lucide-react";
import { jsonLd } from "@/lib/json-ld";

import { CompareMatrix, PseoCta } from "@/components/marketing/PseoSections";
import { AirPage, AirPageHero } from "@/components/marketing/airy/Page";
import { AIR_CELL_LINK, AIR_CHIP, AIR_GRID, AirContainer, AirHeading } from "@/components/marketing/airy/primitives";
import airyCss from "@/styles/airy.css?url";
import { BEST_LISTS } from "@/lib/best-content";
import {
  CATEGORY_LABELS,
  COMPETITORS,
  PSEO_COMPARE_PAGES,
  PSEO_ALTERNATIVE_PAGES,
  captureCatJsonLd,
  comparePath,
  competitorsByCategory,
} from "@/lib/pseo-content";
import { SITE_URL, pageHead } from "@/lib/site-content";

/**
 * /compare, the hub that links every generated comparison and alternative
 * page, so crawlers (and people) can reach all of them from one place.
 */

const jsonLdData = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "CollectionPage",
      "@id": `${SITE_URL}/compare`,
      name: "Compare Screen Recorders",
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
  head: () => pageHead("/compare", [{ rel: "stylesheet", href: airyCss }]),
  component: CompareHubPage,
});

function CompareHubPage() {
  return (
    <AirPage>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(jsonLdData) }}
      />
      <AirPageHero
        pill="Compare"
        icon={<Scale className="h-3.5 w-3.5" strokeWidth={2} />}
        title="How CaptureCat compares"
        lede={`${COMPETITORS.length} screen recorders, feature by feature, including where each of them is genuinely the better pick. Every fact is checked against the product's own site and sourced.`}
      />

      <AirContainer className="pb-12">
        <AirHeading>Best-of lists</AirHeading>
        <div className="mt-6 flex flex-wrap gap-2.5">
          {BEST_LISTS.map((list) => (
            <Link key={list.slug} to="/best/$slug" params={{ slug: list.slug }} className={AIR_CHIP}>
              {list.title}
            </Link>
          ))}
        </div>
      </AirContainer>

      <AirContainer className="pb-8 pt-8">
        <AirHeading>All recorders at a glance</AirHeading>
        <div className="mt-6">
          <CompareMatrix />
        </div>
      </AirContainer>

      {competitorsByCategory().map(([cat, list]) => (
        <AirContainer key={cat} className="pt-14">
          <AirHeading>{CATEGORY_LABELS[cat]}</AirHeading>
          <div className={`${AIR_GRID} mt-6 bg-white md:grid-cols-2`}>
            {list.map((c) => (
              <Link
                key={c.slug}
                to="/compare/$slug"
                params={{ slug: comparePath(c).split("/").pop()! }}
                className={AIR_CELL_LINK}
              >
                <h3 className="flex items-center justify-between gap-4 text-[16px] font-semibold tracking-[-0.01em] text-[var(--cc-air-ink)]">
                  CaptureCat vs {c.name}
                  <span aria-hidden className="text-[var(--cc-air-faint)] transition-transform group-hover:translate-x-0.5">
                    →
                  </span>
                </h3>
                <p className="mt-2 text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">{c.summary}</p>
              </Link>
            ))}
          </div>
        </AirContainer>
      ))}

      <AirContainer className="pt-14">
        <AirHeading>Looking for an alternative?</AirHeading>
        <div className="mt-6 flex flex-wrap gap-2.5">
          {PSEO_ALTERNATIVE_PAGES.map((page) => (
            <Link
              key={page.path}
              to="/alternatives/$slug"
              params={{ slug: page.path.split("/").pop()! }}
              className={AIR_CHIP}
            >
              {page.title}
            </Link>
          ))}
        </div>
      </AirContainer>

      <PseoCta />
    </AirPage>
  );
}
