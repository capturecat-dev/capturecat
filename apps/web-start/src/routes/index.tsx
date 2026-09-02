import { createFileRoute } from "@tanstack/react-router";
import Navbar from "@/components/landing/Navbar";
import Hero from "@/components/landing/Hero";
import Features from "@/components/landing/Features";
import AgentSection from "@/components/landing/AgentSection";
import Footer from "@/components/landing/Footer";
import { markdownAlternateLinks } from "@/lib/site-content";

const jsonLd = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "SoftwareApplication",
      name: "CaptureCat",
      operatingSystem: "macOS",
      applicationCategory: "MultimediaApplication",
      description:
        "A native screen recorder for Mac with automatic cinematic zooms, cursor smoothing, on-device captions, and share links with viewer analytics.",
      url: "https://capturecat.so",
      offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    },
    {
      "@type": "WebSite",
      name: "CaptureCat",
      url: "https://capturecat.so",
    },
  ],
};

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Screen Recorder for Mac — CaptureCat" },
      {
        name: "description",
        content:
          "CaptureCat is a native screen recorder for Mac that edits itself: automatic cinematic zooms, cursor smoothing, on-device captions, device frames, and share links with viewer analytics.",
      },
    ],
    links: markdownAlternateLinks("/"),
  }),
  component: Home,
});

function Home() {
  return (
    <main className="min-h-screen bg-background selection:bg-cyan-500/30 selection:text-cyan-900 dark:selection:text-cyan-100 flex flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <Navbar />
      <Hero />
      <Features />
      <AgentSection />
      <Footer />
    </main>
  );
}
