import { Link, createFileRoute } from "@tanstack/react-router";
import { jsonLd } from "@/lib/json-ld";

import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import { PseoCta } from "@/components/marketing/PseoSections";
import { BEST_LISTS, DISCLOSURE, bestHubJsonLd } from "@/lib/best-content";
import { FACTS_CHECKED } from "@/lib/pseo-content";
import { pageHead } from "@/lib/site-content";

/**
 * /best, the hub that links every best-of list, so crawlers (and people)
 * can reach all of them from one place.
 */

export const Route = createFileRoute("/best/")({
  head: () => pageHead("/best"),
  component: BestHubPage,
});

function BestHubPage() {
  return (
    <main className="min-h-screen bg-background flex flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(bestHubJsonLd()) }}
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
            Best screen recorders ({FACTS_CHECKED.slice(0, 4)})
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-pretty text-lg leading-relaxed text-muted-foreground">
            Lists generated from the same sourced comparison data, checked {FACTS_CHECKED}.
          </p>
          <p className="mx-auto mt-4 max-w-2xl text-pretty text-sm leading-relaxed text-muted-foreground/80">
            {DISCLOSURE}
          </p>
        </div>
      </section>

      <section className="mx-auto w-full max-w-6xl px-6 pb-16">
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          {BEST_LISTS.map((l) => (
            <Link
              key={l.slug}
              to="/best/$slug"
              params={{ slug: l.slug }}
              className="group relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.045] p-6 backdrop-blur-2xl transition-colors hover:bg-white/[0.07]"
            >
              <span
                aria-hidden
                className="absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
              />
              <h2 className="font-medium tracking-[-0.01em]">{l.title}</h2>
              <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                {l.description}
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
