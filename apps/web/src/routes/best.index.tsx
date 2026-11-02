import { Link, createFileRoute } from "@tanstack/react-router";
import { ListOrdered } from "lucide-react";
import { jsonLd } from "@/lib/json-ld";

import { PseoCta } from "@/components/marketing/PseoSections";
import { BEST_LISTS, DISCLOSURE, bestHubJsonLd } from "@/lib/best-content";
import { FACTS_CHECKED } from "@/lib/pseo-content";
import { pageHead } from "@/lib/site-content";
import { AirPage, AirPageHero } from "@/components/marketing/airy/Page";
import { AIR_CELL_LINK, AIR_GRID, AirContainer } from "@/components/marketing/airy/primitives";
import airyCss from "@/styles/airy.css?url";

/**
 * /best, the hub that links every best-of list, so crawlers (and people)
 * can reach all of them from one place.
 */

export const Route = createFileRoute("/best/")({
  head: () => pageHead("/best", [{ rel: "stylesheet", href: airyCss }]),
  component: BestHubPage,
});

function BestHubPage() {
  return (
    <AirPage>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(bestHubJsonLd()) }}
      />
      <AirPageHero
        pill="Best-of lists"
        icon={<ListOrdered className="h-3.5 w-3.5" strokeWidth={2} />}
        title={`Best screen recorders (${FACTS_CHECKED.slice(0, 4)})`}
        lede={`Lists generated from the same sourced comparison data, checked ${FACTS_CHECKED}.`}
      >
        <p className="mt-4 max-w-2xl text-pretty text-[13.5px] leading-relaxed text-[var(--cc-air-faint)]">{DISCLOSURE}</p>
      </AirPageHero>

      <AirContainer>
        <div className={`${AIR_GRID} bg-white md:grid-cols-2`}>
          {BEST_LISTS.map((l) => (
            <Link key={l.slug} to="/best/$slug" params={{ slug: l.slug }} className={AIR_CELL_LINK}>
              <h2 className="flex items-center justify-between gap-4 text-[16px] font-semibold tracking-[-0.01em] text-[var(--cc-air-ink)]">
                {l.title}
                <span aria-hidden className="shrink-0 text-[var(--cc-air-faint)] transition-transform group-hover:translate-x-0.5">
                    →
                  </span>
              </h2>
              <p className="mt-2 text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">{l.description}</p>
            </Link>
          ))}
        </div>
      </AirContainer>

      <PseoCta />
    </AirPage>
  );
}
