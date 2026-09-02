import { createFileRoute } from "@tanstack/react-router";

import Navbar from "@/components/landing/Navbar";
import Footer from "@/components/landing/Footer";
import { BetaForm } from "@/components/landing/BetaForm";

// Deliberately unlinked and non-indexed: the URL is shared directly, not
// discovered. Kept out of SITE_PAGES too, so it has no Markdown twin.
export const Route = createFileRoute("/beta")({
  head: () => ({
    meta: [
      { title: "Join the Beta | CaptureCat" },
      {
        name: "description",
        content:
          "Get early access to CaptureCat. Drop your email to join the beta and we'll be in touch.",
      },
      { name: "robots", content: "noindex, nofollow" },
    ],
  }),
  component: BetaPage,
});

function BetaPage() {
  return (
    <main className="min-h-screen bg-background flex flex-col selection:bg-cyan-500/30 selection:text-cyan-900 dark:selection:text-cyan-100">
      <Navbar />

      <section className="relative isolate flex flex-1 items-center overflow-hidden">
        {/* Ambient light — same treatment as the hero, so glass has something to catch. */}
        <div
          aria-hidden
          className="pointer-events-none absolute inset-0 -z-10"
          style={{
            background:
              "radial-gradient(120% 80% at 50% -20%, rgba(120,140,255,0.22), transparent 60%)," +
              "radial-gradient(90% 60% at 85% 10%, rgba(80,220,255,0.14), transparent 55%)," +
              "radial-gradient(70% 50% at 10% 30%, rgba(190,120,255,0.12), transparent 60%)",
          }}
        />

        <div className="mx-auto flex w-full max-w-6xl flex-col items-center px-6 py-20 md:py-28">
          <span className="inline-flex items-center gap-2 rounded-full border border-white/12 bg-white/[0.06] px-4 py-1.5 text-[13px] text-muted-foreground backdrop-blur-xl">
            <span className="h-1.5 w-1.5 rounded-full bg-cyan-300/80" />
            Private beta
          </span>

          <h1 className="mt-8 max-w-2xl text-balance text-center text-4xl font-semibold leading-[1.05] tracking-[-0.03em] text-foreground md:text-6xl">
            Get early access to{" "}
            <span className="bg-gradient-to-b from-white to-white/55 bg-clip-text text-transparent">
              CaptureCat.
            </span>
          </h1>

          <p className="mt-6 max-w-lg text-pretty text-center text-lg leading-relaxed text-muted-foreground">
            Drop your email to join the beta. We&rsquo;ll send an invite as soon
            as a spot opens up — no spam, ever.
          </p>

          <div className="mt-12 flex w-full justify-center">
            <BetaForm />
          </div>
        </div>
      </section>

      <Footer />
    </main>
  );
}
