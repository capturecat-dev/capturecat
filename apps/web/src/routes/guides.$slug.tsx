import { Link, createFileRoute, notFound } from "@tanstack/react-router";
import { jsonLd } from "@/lib/json-ld";

import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import { FaqSection, PseoCta } from "@/components/marketing/PseoSections";
import {
  findGuide,
  guideJsonLd,
  guidePath,
  relatedGuides,
} from "@/lib/guides-content";
import { markdownAlternateLinks } from "@/lib/site-content";

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
    if (!guide) return {};
    return {
      meta: [
        { title: `${guide.question} | CaptureCat` },
        { name: "description", content: guide.description },
      ],
      links: markdownAlternateLinks(guidePath(guide)),
    };
  },
  component: GuidePage,
});

const glassCard =
  "relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-6 backdrop-blur-2xl md:p-8";

function TopHairline() {
  return (
    <span
      aria-hidden
      className="absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
    />
  );
}

function GuidePage() {
  const { guide } = Route.useLoaderData();
  const related = relatedGuides(guide);

  return (
    <main className="min-h-screen bg-background flex flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(guideJsonLd(guide)) }}
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
            to="/guides"
            className="text-sm font-medium uppercase tracking-[0.14em] text-muted-foreground transition-colors hover:text-foreground"
          >
            Guide
          </Link>
          <h1 className="mt-3 text-balance text-4xl font-semibold leading-[1.08] tracking-[-0.03em] md:text-5xl">
            {guide.question}
          </h1>
          <div className={`mt-8 ${glassCard}`}>
            <TopHairline />
            <p className="text-xs font-medium uppercase tracking-[0.14em] text-muted-foreground">
              Short answer
            </p>
            <p className="mt-3 text-pretty text-lg leading-relaxed">{guide.answer}</p>
          </div>
        </div>
      </section>

      {guide.without && (
        <section className="mx-auto w-full max-w-3xl px-6 pb-6">
          <h2 className="text-2xl font-semibold tracking-[-0.02em]">{guide.without.title}</h2>
          <p className="mt-3 text-pretty leading-relaxed text-muted-foreground">
            {guide.without.text}
          </p>
        </section>
      )}

      <section className="mx-auto w-full max-w-3xl px-6 py-10">
        <h2 className="text-2xl font-semibold tracking-[-0.02em]">Steps with CaptureCat</h2>
        <ol className="mt-6 space-y-4">
          {guide.steps.map((step, i) => (
            <li key={step.name} className={`${glassCard} flex gap-5`}>
              <TopHairline />
              <span
                aria-hidden
                className="flex size-8 shrink-0 items-center justify-center rounded-full border border-white/15 bg-white/[0.06] text-sm font-medium tabular-nums"
              >
                {i + 1}
              </span>
              <div>
                <h3 className="font-medium tracking-[-0.01em]">{step.name}</h3>
                <p className="mt-1.5 text-sm leading-relaxed text-muted-foreground">
                  {step.text}
                </p>
              </div>
            </li>
          ))}
        </ol>
      </section>

      {guide.tips && guide.tips.length > 0 && (
        <section className="mx-auto w-full max-w-3xl px-6 pb-4">
          <h2 className="text-2xl font-semibold tracking-[-0.02em]">Tips</h2>
          <ul className="mt-4 list-disc space-y-2 pl-5 text-sm leading-relaxed text-muted-foreground marker:text-white/30">
            {guide.tips.map((tip) => (
              <li key={tip}>{tip}</li>
            ))}
          </ul>
        </section>
      )}

      <FaqSection faqs={guide.faqs} />

      {related.length > 0 && (
        <section className="mx-auto w-full max-w-6xl px-6 pb-16">
          <h2 className="text-2xl font-semibold tracking-[-0.02em]">Related guides</h2>
          <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-3">
            {related.map((r) => (
              <Link
                key={r.slug}
                to="/guides/$slug"
                params={{ slug: r.slug }}
                className="group relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-6 backdrop-blur-2xl transition-colors hover:bg-white/[0.07]"
              >
                <TopHairline />
                <h3 className="font-medium tracking-[-0.01em]">{r.label}</h3>
                <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                  {r.question}
                </p>
              </Link>
            ))}
          </div>
        </section>
      )}

      <PseoCta />

      <Footer />
    </main>
  );
}
