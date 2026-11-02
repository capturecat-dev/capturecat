import { createFileRoute } from "@tanstack/react-router";
import { CreditCard, Gauge, LayoutGrid, Tag, WifiOff } from "lucide-react";

import { jsonLd } from "@/lib/json-ld";
import { API_URL } from "@/lib/api-url";
import { pageHead } from "@/lib/site-content";
import { PricingCards, type PlanView } from "@/components/marketing/pricing-cards";
import { DashboardDemo } from "@/components/marketing/home/demo/DashboardDemo";
import demosCss from "@/styles/demos.css?url";
import demosPagesCss from "@/styles/demos-pages.css?url";
import airyCss from "@/styles/airy.css?url";
import type { FaqItem } from "@/components/marketing/home/Faq";
import { AirPage, AirPageHero } from "@/components/marketing/airy/Page";
import { AirFaq } from "@/components/marketing/airy/Faq";
import {
  AIR_CELL,
  AIR_GRID,
  AirContainer,
  AirLede,
  AirPill,
  AirTitle,
  SoftFrame,
} from "@/components/marketing/airy/primitives";

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
  head: () =>
    pageHead("/pricing", [
      { rel: "stylesheet", href: demosCss },
      { rel: "stylesheet", href: demosPagesCss },
      { rel: "stylesheet", href: airyCss },
    ]),
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

/** The three things Free and Pro both promise. */
const PROMISES = [
  {
    icon: Gauge,
    title: "No resolution cap",
    body: "Free exports go up to 4K at 60 fps with every effect on and no watermark. Free is the whole app, not a demo of it.",
  },
  {
    icon: WifiOff,
    title: "No account to record",
    body: "On the Mac you only sign in for a share link or for Pro. Free recording and editing work offline.",
  },
  {
    icon: CreditCard,
    title: "Cancel from the billing page",
    body: "One click, no email to support. Stripe handles the card, we never see the number.",
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
    <AirPage>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(jsonLdData) }}
      />
      <AirPageHero
        pill="Pricing"
        icon={<Tag className="h-3.5 w-3.5" strokeWidth={2} />}
        title="Free for personal use. Pro for work."
        lede="The whole app is free for personal projects, with recordings up to 5 minutes. Pro is for commercial use: recordings of any length, plus share pages, comments and analytics. Prices below are live from Stripe."
        className="md:pb-24"
      >
        <div className="mt-14 w-full text-left">
          <PricingCards plan={plan} />
        </div>
      </AirPageHero>

      <section className="py-24 md:py-32">
        <AirContainer>
          <div className="grid grid-cols-1 items-center gap-12 lg:grid-cols-12 lg:gap-14">
            <div className="scroll-reveal lg:col-span-5">
              <AirPill icon={<LayoutGrid className="h-3.5 w-3.5" strokeWidth={2} />}>Pro on the web</AirPill>
              <AirTitle className="mt-5 !text-[28px] md:!text-[32px]" muted="Every shared video, its link, and how it did.">
                What Pro looks like from the web.
              </AirTitle>
              <AirLede className="mt-4">
                Uploads from the app land here. Rename a video, flip it between public and private, read the
                comments, and open the analytics for any of them. Links use your own custom domain if you set one up.
              </AirLede>
            </div>
            <div className="scroll-reveal lg:col-span-7">
              <SoftFrame>
                <DashboardDemo />
              </SoftFrame>
            </div>
          </div>
        </AirContainer>
      </section>

      <section className="border-t border-[var(--cc-air-hairline)] bg-white py-20 md:py-24">
        <AirContainer>
          <div className={`${AIR_GRID} md:grid-cols-3`}>
            {PROMISES.map((p) => (
              <div key={p.title} className={`${AIR_CELL} p-7 md:p-8`}>
                <p.icon className="h-5 w-5 text-[var(--cc-air-violet)]" strokeWidth={1.75} />
                <h3 className="mt-5 text-[16px] font-semibold tracking-[-0.01em] text-[var(--cc-air-ink)]">{p.title}</h3>
                <p className="mt-1.5 text-[14.5px] leading-relaxed text-[var(--cc-air-muted)]">{p.body}</p>
              </div>
            ))}
          </div>
        </AirContainer>
      </section>

      <AirFaq items={PRICING_FAQ} title="Pricing questions" />
    </AirPage>
  );
}
