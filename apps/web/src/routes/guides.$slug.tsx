import { Link, createFileRoute, notFound } from "@tanstack/react-router";
import { jsonLd } from "@/lib/json-ld";

import { FaqSection, PseoCta } from "@/components/marketing/PseoSections";
import {
  findGuide,
  guideJsonLd,
  guidePath,
  relatedGuides,
} from "@/lib/guides-content";
import { pageHead } from "@/lib/site-content";
import { AirPage, AirPageHero, BackPill } from "@/components/marketing/airy/Page";
import {
  AIR_CELL_LINK,
  AIR_GRID,
  AirCard,
  AirContainer,
  AirHeading,
} from "@/components/marketing/airy/primitives";
import airyCss from "@/styles/airy.css?url";

/**
 * /guides/{slug}: job-to-be-done how-to pages. Content, Markdown twin, and
 * JSON-LD all come from lib/guides-content.ts.
 */

export const Route = createFileRoute("/guides/$slug")({
  loader: async ({ params }) => {
    const guide = findGuide(params.slug);
    if (!guide) throw notFound();
    return { guide };
  },
  head: ({ params }) => {
    const guide = findGuide(params.slug);
    return guide ? pageHead(guidePath(guide), [{ rel: "stylesheet", href: airyCss }]) : {};
  },
  component: GuidePage,
});

function GuidePage() {
  const { guide } = Route.useLoaderData();
  const related = relatedGuides(guide);

  return (
    <AirPage>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(guideJsonLd(guide)) }}
      />
      <AirPageHero
        before={<BackPill to="/guides">Guide</BackPill>}
        align="left"
        compact
        title={guide.question}
        className="!max-w-3xl md:!pb-14"
      >
        <AirCard className="mt-8 p-6 md:p-7">
          <p className="text-xs font-medium uppercase tracking-[0.12em] text-[var(--cc-air-faint)]">Short answer</p>
          <p className="mt-3 text-pretty text-[18px] leading-relaxed text-[var(--cc-air-ink)]">{guide.answer}</p>
        </AirCard>
      </AirPageHero>

      {guide.without && (
        <AirContainer className="!max-w-3xl pb-6">
          <AirHeading>{guide.without.title}</AirHeading>
          <p className="mt-3 text-pretty text-[15.5px] leading-relaxed text-[var(--cc-air-muted)]">{guide.without.text}</p>
        </AirContainer>
      )}

      <AirContainer className="!max-w-3xl py-10">
        <AirHeading>Steps with CaptureCat</AirHeading>
        <ol className="mt-6 space-y-4">
          {guide.steps.map((step, i) => (
            <AirCard key={step.name} as="li" className="flex gap-5 p-6 md:p-7">
              <span
                aria-hidden
                className="flex size-8 shrink-0 items-center justify-center rounded-full bg-[var(--cc-air-ink)] text-sm font-semibold tabular-nums text-white"
              >
                {i + 1}
              </span>
              <div>
                <h3 className="text-[16px] font-semibold tracking-[-0.01em] text-[var(--cc-air-ink)]">{step.name}</h3>
                <p className="mt-1.5 text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">{step.text}</p>
              </div>
            </AirCard>
          ))}
        </ol>
      </AirContainer>

      {guide.tips && guide.tips.length > 0 && (
        <AirContainer className="!max-w-3xl pb-16">
          <AirHeading>Tips</AirHeading>
          <ul className="mt-5 space-y-2.5">
            {guide.tips.map((tip) => (
              <li key={tip} className="flex gap-2.5 text-[15px] leading-relaxed text-[var(--cc-air-muted)]">
                <span aria-hidden className="mt-[10px] h-1 w-1 shrink-0 rounded-full bg-[var(--cc-air-violet)]" />
                {tip}
              </li>
            ))}
          </ul>
        </AirContainer>
      )}

      <FaqSection faqs={guide.faqs} />

      {related.length > 0 && (
        <AirContainer className="pt-20">
          <AirHeading>Related guides</AirHeading>
          <div className={`${AIR_GRID} mt-6 bg-white md:grid-cols-3`}>
            {related.map((r) => (
              <Link key={r.slug} to="/guides/$slug" params={{ slug: r.slug }} className={AIR_CELL_LINK}>
                <h3 className="text-[16px] font-semibold tracking-[-0.01em] text-[var(--cc-air-ink)]">{r.label}</h3>
                <p className="mt-2 text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">{r.question}</p>
              </Link>
            ))}
          </div>
        </AirContainer>
      )}

      <PseoCta />
    </AirPage>
  );
}
