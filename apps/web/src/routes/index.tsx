import { createFileRoute } from "@tanstack/react-router";

import { jsonLd } from "@/lib/json-ld";
import { markdownAlternateLinks } from "@/lib/site-content";
import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import Hero from "@/components/marketing/home/Hero";
import BeforeAfter from "@/components/marketing/home/BeforeAfter";
import HowItWorks from "@/components/marketing/home/HowItWorks";
import FeatureShowcase from "@/components/marketing/home/FeatureShowcase";
import ShareSection from "@/components/marketing/home/ShareSection";
import AgentSection from "@/components/marketing/AgentSection";
import UseCases from "@/components/marketing/home/UseCases";
import OpenSource from "@/components/marketing/home/OpenSource";
import FeatureInventory from "@/components/marketing/FeatureInventory";
import Faq, { HOME_FAQ } from "@/components/marketing/home/Faq";
import FinalCta from "@/components/marketing/home/FinalCta";

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
      offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    },
    {
      "@type": "WebSite",
      name: "CaptureCat",
      url: "https://capturecat.so",
    },
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
  head: () => ({
    meta: [
      { title: "CaptureCat: the Mac screen recorder that edits itself" },
      {
        name: "description",
        content:
          "CaptureCat records your Mac and adds the zooms, cursor smoothing, and captions automatically. Native Swift, free to record and export, with share links and viewer analytics on Pro.",
      },
    ],
    links: markdownAlternateLinks("/"),
  }),
  component: Home,
});

function Home() {
  return (
    <main className="flex min-h-screen flex-col bg-background selection:bg-cyan-500/30 selection:text-cyan-100">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(jsonLdData) }}
      />
      <Navbar />
      <Hero />
      <BeforeAfter />
      <HowItWorks />
      <FeatureShowcase />
      <ShareSection />
      <AgentSection />
      <UseCases />
      <OpenSource />
      <FeatureInventory />
      <Faq />
      <FinalCta />
      <Footer />
    </main>
  );
}
