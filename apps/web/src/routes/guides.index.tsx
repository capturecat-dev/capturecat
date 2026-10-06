import { Link, createFileRoute } from "@tanstack/react-router";
import { jsonLd } from "@/lib/json-ld";

import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import { PseoCta } from "@/components/marketing/PseoSections";
import {
  GUIDES,
  GUIDES_HUB_DESCRIPTION,
  guidesHubJsonLd,
} from "@/lib/guides-content";
import { markdownAlternateLinks } from "@/lib/site-content";

/**
 * /guides, the hub that links every how-to guide, so crawlers (and people)
 * can reach all of them from one place.
 */

export const Route = createFileRoute("/guides/")({
  head: () => ({
    meta: [
      { title: "Screen Recording Guides | CaptureCat" },
      { name: "description", content: GUIDES_HUB_DESCRIPTION },
    ],
    links: markdownAlternateLinks("/guides"),
  }),
  component: GuidesHubPage,
});

function GuidesHubPage() {
  return (
    <main className="min-h-screen bg-background flex flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(guidesHubJsonLd()) }}
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
            Get the recording done
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-pretty text-lg leading-relaxed text-muted-foreground">
            Short answers to the jobs people actually have: zooming in on
            clicks, captions without uploading, blurring a secret, recording an
            iPhone, and letting an AI agent do the edit.
          </p>
        </div>
      </section>

      <section className="mx-auto w-full max-w-6xl px-6 pb-16">
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          {GUIDES.map((g) => (
            <Link
              key={g.slug}
              to="/guides/$slug"
              params={{ slug: g.slug }}
              className="group relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-6 backdrop-blur-2xl transition-colors hover:bg-white/[0.07]"
            >
              <span
                aria-hidden
                className="absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
              />
              <h2 className="font-medium tracking-[-0.01em]">{g.question}</h2>
              <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                {g.description}
              </p>
            </Link>
          ))}
        </div>
      </section>

      <PseoCta />

      <Footer />
    </main>
  );
}
