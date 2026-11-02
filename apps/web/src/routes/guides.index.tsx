import { Link, createFileRoute } from "@tanstack/react-router";
import { BookOpen } from "lucide-react";
import { jsonLd } from "@/lib/json-ld";

import { PseoCta } from "@/components/marketing/PseoSections";
import { GUIDES, guidesHubJsonLd } from "@/lib/guides-content";
import { pageHead } from "@/lib/site-content";
import { AirPage, AirPageHero } from "@/components/marketing/airy/Page";
import { AIR_CELL_LINK, AIR_GRID, AirContainer } from "@/components/marketing/airy/primitives";
import airyCss from "@/styles/airy.css?url";

/**
 * /guides, the hub that links every how-to guide, so crawlers (and people)
 * can reach all of them from one place.
 */

export const Route = createFileRoute("/guides/")({
  head: () => pageHead("/guides", [{ rel: "stylesheet", href: airyCss }]),
  component: GuidesHubPage,
});

function GuidesHubPage() {
  return (
    <AirPage>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(guidesHubJsonLd()) }}
      />
      <AirPageHero
        pill="Guides"
        icon={<BookOpen className="h-3.5 w-3.5" strokeWidth={2} />}
        title="Get the recording done"
        lede="Short answers to the jobs people actually have: zooming in on clicks, captions without uploading, blurring a secret, recording an iPhone, and letting an AI agent do the edit."
      />

      <AirContainer>
        <div className={`${AIR_GRID} bg-white md:grid-cols-2`}>
          {GUIDES.map((g) => (
            <Link key={g.slug} to="/guides/$slug" params={{ slug: g.slug }} className={AIR_CELL_LINK}>
              <h2 className="flex items-start justify-between gap-4 text-[16px] font-semibold leading-snug tracking-[-0.01em] text-[var(--cc-air-ink)]">
                {g.question}
                <span aria-hidden className="shrink-0 text-[var(--cc-air-faint)] transition-transform group-hover:translate-x-0.5">
                    →
                  </span>
              </h2>
              <p className="mt-2 text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">{g.description}</p>
            </Link>
          ))}
        </div>
      </AirContainer>

      <PseoCta />
    </AirPage>
  );
}
