import { createFileRoute } from "@tanstack/react-router";

import Navbar from "@/components/landing/Navbar";
import Footer from "@/components/landing/Footer";
import { API_URL } from "@/lib/api-url";
import { markdownAlternateLinks } from "@/lib/site-content";
import { PricingCards, type PlanView } from "@/components/marketing/pricing-cards";

/**
 * The price AND the feature list come from the API (Stripe + the D1 plan
 * rows), not from this file. Falls back to static copy if billing is
 * unconfigured so the page still renders.
 */
async function getPlan(): Promise<PlanView | null> {
  try {
    const res = await fetch(`${API_URL}/api/plans`);
    if (!res.ok) return null;
    return (await res.json()) as PlanView;
  } catch {
    return null;
  }
}

export const Route = createFileRoute("/pricing")({
  loader: async () => ({ plan: await getPlan() }),
  head: () => ({
    meta: [
      { title: "Pricing | CaptureCat" },
      {
        name: "description",
        content:
          "CaptureCat pricing — a free Mac screen recorder with a Pro plan for cloud sharing, comments, and viewer analytics. Prices come live from Stripe.",
      },
    ],
    links: markdownAlternateLinks("/pricing"),
  }),
  component: PricingPage,
});

function PricingPage() {
  const { plan } = Route.useLoaderData();

  const jsonLd = {
    "@context": "https://schema.org",
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
  };

  return (
    <main className="min-h-screen bg-background flex flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <Navbar />

      <div className="flex-1 flex flex-col items-center px-6 pb-28 pt-20">
        <div className="text-center space-y-4 mb-12">
          <h1 className="text-4xl md:text-5xl font-semibold tracking-[-0.03em]">
            Simple pricing
          </h1>
          <p className="text-lg text-muted-foreground max-w-lg mx-auto">
            The recorder and editor are free. Pro adds sharing, comments, and
            analytics.
          </p>
        </div>

        <PricingCards plan={plan} />
      </div>

      <Footer />
    </main>
  );
}
