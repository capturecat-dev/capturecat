import { createFileRoute } from "@tanstack/react-router";

import { jsonLd } from "@/lib/json-ld";
import { API_URL } from "@/lib/api-url";
import { pageHead } from "@/lib/site-content";
import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import { PricingCards, type PlanView } from "@/components/marketing/pricing-cards";
import { DashboardDemo } from "@/components/marketing/home/demo/DashboardDemo";
import demosCss from "@/styles/demos.css?url";
import demosPagesCss from "@/styles/demos-pages.css?url";
import { FaqList, type FaqItem } from "@/components/marketing/home/Faq";
import {
  Ambient,
  Container,
  Eyebrow,
  GlassCard,
  SectionTitle,
} from "@/components/marketing/primitives";

/**
 * The price and the gated feature list come from the API (Stripe plus the D1
 * plan rows), not from this file. Falls back to static copy if billing is
 * unconfigured so the page still renders.
 */
async function getPlan(): Promise<PlanView | null> {
  try {
    const res = await fetch(`${API_URL}/api/plans`, {
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) return null;
    return (await res.json()) as PlanView;
  } catch {
    return null;
  }
}

export const Route = createFileRoute("/pricing")({
  loader: async () => ({ plan: await getPlan() }),
  head: () => pageHead("/pricing", [{ rel: "stylesheet", href: demosCss }, { rel: "stylesheet", href: demosPagesCss }]),
  component: PricingPage,
});

export const PRICING_FAQ: FaqItem[] = [
  {
    q: "What exactly is free?",
    a: "The whole app, for personal use: recording from any source, the editor, auto zoom, cursor smoothing, captions, device frames, the camera bubble, annotations, and export up to 4K with no watermark. Each recording stops at 5 minutes, and Free includes a small cloud allowance for short share links.",
  },
  {
    q: "What counts as commercial use?",
    a: "Recording or editing anything used in work that earns money: client work, courses, marketing, demos of your employer's product, and videos for your team at a company. Commercial use needs Pro. Personal projects, learning, and hobby videos are fine on Free.",
  },
  {
    q: "So what am I paying for with Pro?",
    a: "Commercial use and recordings of any length, plus the hosted side at full size: uploads to a capturecat.so share page, public and private links, timestamped comments from viewers, per video analytics, and web capture by URL. Storage and per video limits are shown on the cards above and come from your plan.",
  },
  {
    q: "Is there a trial?",
    a: "When a trial is enabled it shows as a badge on the Pro card, with the number of days. You will not be charged until the trial ends, and you can cancel from the billing page before then.",
  },
  {
    q: "Can I pay yearly?",
    a: "Yes. The Monthly and Annual switch above shows both prices and the saving. Both renew until you cancel.",
  },
  {
    q: "How do I cancel?",
    a: "From the billing page in your account. Access to Pro features runs to the end of the paid period, then your account is on Free again: personal use, with new recordings stopping at 5 minutes. Recordings and exports you already made are untouched.",
  },
  {
    q: "What happens to my shared videos if I stop paying?",
    a: "If they fit Free's cloud allowance they keep playing; past it, your links pause until you free up space or resubscribe, and the same links come back. Nothing on your Mac is touched.",
  },
  {
    q: "Do you offer refunds?",
    a: "UK consumer law applies. You have a 14 day right to cancel, and if the service does not do what the site says it does, email contact@capturecat.so and we will sort it out.",
  },
  {
    q: "Is there a team plan?",
    a: "Not yet. Pro is per person. If you need seats for a team, email contact@capturecat.so and say how many.",
  },
];

function PricingPage() {
  const { plan } = Route.useLoaderData();

  const jsonLdData = {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "SoftwareApplication",
        name: "CaptureCat",
        operatingSystem: "macOS",
        applicationCategory: "MultimediaApplication",
        offers: [
          {
            "@type": "Offer",
            name: plan?.free?.name ?? "Free",
            price: "0",
            priceCurrency: (plan?.monthly.currency ?? "usd").toUpperCase(),
          },
          ...(plan?.monthly.amount
            ? [
                {
                  "@type": "Offer",
                  name: plan.name,
                  price: (plan.monthly.amount / 100).toFixed(2),
                  priceCurrency: plan.monthly.currency.toUpperCase(),
                },
              ]
            : []),
        ],
      },
      {
        "@type": "FAQPage",
        mainEntity: PRICING_FAQ.map((f) => ({
          "@type": "Question",
          name: f.q,
          acceptedAnswer: { "@type": "Answer", text: f.a },
        })),
      },
    ],
  };

  return (
    <main className="flex min-h-screen flex-col bg-background">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(jsonLdData) }}
      />
      <Navbar />

      <section className="relative isolate overflow-hidden">
        <Ambient variant="hero" />
        <Container className="flex flex-col items-center pb-20 pt-16 md:pt-24">
          <Eyebrow>Pricing</Eyebrow>
          <h1 className="mt-6 max-w-3xl text-balance text-center text-5xl font-semibold leading-[1.04] tracking-[-0.03em] md:text-6xl">
            Free for personal use. Pro for work.
          </h1>
          <p className="mx-auto mt-6 max-w-xl text-pretty text-center text-lg leading-relaxed text-muted-foreground">
            The whole app is free for personal projects, with recordings up to
            5 minutes. Pro is for commercial use: recordings of any length,
            plus share pages, comments, and analytics. Prices below are live
            from Stripe.
          </p>

          <div className="mt-14 w-full">
            <PricingCards plan={plan} />
          </div>
        </Container>
      </section>

      <section className="relative isolate py-16">
        <Container>
          <div className="grid grid-cols-1 items-center gap-10 lg:grid-cols-12 lg:gap-14">
            <div className="lg:col-span-5">
              <SectionTitle muted="Every shared video, its link, and how it did.">
                What Pro looks like from the web.
              </SectionTitle>
              <p className="mt-5 text-[15.5px] leading-relaxed text-muted-foreground">
                Uploads from the app land here. Rename a video, flip it between
                public and private, read the comments, and open the analytics
                for any of them. Links use your own custom domain if you set
                one up.
              </p>
            </div>
            <div className="lg:col-span-7">
              <DashboardDemo />
            </div>
          </div>
        </Container>
      </section>

      <section className="relative isolate py-16">
        <Container>
          <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
            <GlassCard padding="p-7">
              <h3 className="text-[17px] font-medium tracking-[-0.01em]">No resolution cap</h3>
              <p className="mt-2 text-[14.5px] leading-relaxed text-muted-foreground">
                Free exports go up to 4K at 60 fps with every effect on and no
                watermark. Free is the whole app, not a demo of it.
              </p>
            </GlassCard>
            <GlassCard padding="p-7">
              <h3 className="text-[17px] font-medium tracking-[-0.01em]">No account to record</h3>
              <p className="mt-2 text-[14.5px] leading-relaxed text-muted-foreground">
                On the Mac you only sign in for a share link or for Pro. Free
                recording and editing work offline.
              </p>
            </GlassCard>
            <GlassCard padding="p-7">
              <h3 className="text-[17px] font-medium tracking-[-0.01em]">Cancel from the billing page</h3>
              <p className="mt-2 text-[14.5px] leading-relaxed text-muted-foreground">
                One click, no email to support. Stripe handles the card, we
                never see the number.
              </p>
            </GlassCard>
          </div>
        </Container>
      </section>

      <section className="relative isolate py-16 pb-28">
        <Container>
          <SectionTitle>Pricing questions</SectionTitle>
          <div className="mt-10 max-w-3xl">
            <FaqList items={PRICING_FAQ} />
          </div>
        </Container>
      </section>

      <Footer />
    </main>
  );
}
