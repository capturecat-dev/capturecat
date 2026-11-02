import { createFileRoute } from "@tanstack/react-router";

import { ORGANIZATION_JSON_LD, jsonLd } from "@/lib/json-ld";
import { pageHead } from "@/lib/site-content";
import { CAPTURECAT_OFFERS } from "@/lib/pseo-content";
import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import { HOME_FAQ } from "@/components/marketing/home/Faq";
import AirHero from "@/components/marketing/airy/Hero";
import FeatureRows from "@/components/marketing/airy/FeatureRows";
import {
  AgentsBand,
  AirFaq,
  AirFinalCta,
  CapabilityBand,
  DetailCards,
  Everywhere,
  FeatureGrid,
  Statement,
} from "@/components/marketing/airy/Sections";
import demosCss from "@/styles/demos.css?url";
import airyCss from "@/styles/airy.css?url";

const jsonLdData = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "SoftwareApplication",
      name: "CaptureCat",
      operatingSystem: "macOS",
      applicationCategory: "MultimediaApplication",
      description:
        "A native screen recorder for Mac that adds zooms, smooths the cursor, and writes captions automatically, with share links and viewer analytics.",
      url: "https://capturecat.so",
      offers: CAPTURECAT_OFFERS,
      publisher: { "@id": ORGANIZATION_JSON_LD["@id"] },
    },
    {
      "@type": "WebSite",
      name: "CaptureCat",
      url: "https://capturecat.so",
      publisher: { "@id": ORGANIZATION_JSON_LD["@id"] },
    },
    ORGANIZATION_JSON_LD,
    {
      "@type": "FAQPage",
      mainEntity: HOME_FAQ.map((f) => ({
        "@type": "Question",
        name: f.q,
        acceptedAnswer: { "@type": "Answer", text: f.a },
      })),
    },
  ],
};

export const Route = createFileRoute("/")({
  head: () => pageHead("/", [
    { rel: "stylesheet", href: demosCss },
    { rel: "stylesheet", href: airyCss },
  ]),
  component: Home,
});

function Home() {
  return (
    // The light, airy home (styles/airy.css): `data-cc-light` re-points the
    // theme tokens while this page is mounted; every other page stays dark.
    <main data-cc-light className="flex min-h-screen flex-col bg-background text-foreground selection:bg-violet-500/20">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(jsonLdData) }}
      />
      <Navbar />
      <AirHero />
      <CapabilityBand />
      <FeatureRows />
      <Everywhere />
      <DetailCards />
      <Statement />
      <AgentsBand />
      <FeatureGrid />
      <AirFaq />
      <AirFinalCta />
      <Footer />
    </main>
  );
}
