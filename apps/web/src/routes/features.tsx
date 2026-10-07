import { createFileRoute } from "@tanstack/react-router";
import {
  Monitor,
  Smartphone,
  Globe,
  Search,
  Keyboard,
  PenTool,
  Download,
  HardDrive,
} from "lucide-react";

import { jsonLd } from "@/lib/json-ld";
import { pageHead } from "@/lib/site-content";
import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import FeatureInventory from "@/components/marketing/FeatureInventory";
import FinalCta from "@/components/marketing/home/FinalCta";
import { PinnedStory } from "@/components/marketing/home/demo/PinnedStory";
import {
  AnnotationsScene,
  ExportScene,
  IPhoneScene,
  KeystrokesScene,
  LibraryScene,
  SceneSlot,
  WebCaptureScene,
} from "@/components/marketing/home/demo/Scenes";
import demosCss from "@/styles/demos.css?url";
import demosPagesCss from "@/styles/demos-pages.css?url";
import {
  Ambient,
  AppleGlyph,
  Container,
  Eyebrow,
  IconTile,
  PrimaryLink,
  SecondaryLink,
} from "@/components/marketing/primitives";

export const Route = createFileRoute("/features")({
  head: () => pageHead("/features", [{ rel: "stylesheet", href: demosCss }, { rel: "stylesheet", href: demosPagesCss }]),
  component: FeaturesPage,
});

const jsonLdData = {
  "@context": "https://schema.org",
  "@type": "WebPage",
  name: "CaptureCat features",
  url: "https://capturecat.so/features",
  description: "The complete feature list for CaptureCat, the Mac screen recorder that edits itself.",
};

/**
 * The home page covers the headline features. This page covers the ones that
 * did not fit there, then the full inventory.
 */
const SECTIONS: Array<{
  icon: typeof Monitor;
  eyebrow: string;
  title: string;
  body: string;
  details: string[];
}> = [
  {
    icon: Smartphone,
    eyebrow: "Record an iPhone or iPad",
    title: "Plug in the phone. Record it like a window.",
    body:
      "Connect an iPhone or iPad over USB and it shows up as a source next to your displays and windows. The export wraps it in a photoreal bezel with the right corner radius and notch for that model, sitting on whatever background you chose.",
    details: [
      "Taps are recorded as data, so tap indicators can be styled afterwards",
      "Same auto zoom, captions, and framing as a Mac recording",
      "Portrait 9:16 export for App Store previews and social",
    ],
  },
  {
    icon: Globe,
    eyebrow: "Capture a web page by URL",
    title: "A clean screenshot of any page, without the clutter.",
    body:
      "Paste a URL and pick a viewport: desktop, tablet, or mobile. CaptureCat loads the page, strips cookie banners and chat widgets, optionally switches it to dark mode, and captures the full scroll height in one image.",
    details: [
      "Desktop, tablet, and mobile viewports",
      "Full page height, not just the first screen",
      "Cookie banners and chat widgets removed before capture",
    ],
  },
  {
    icon: PenTool,
    eyebrow: "Annotations",
    title: "Arrows, callouts, and drawings that animate in.",
    body:
      "Text, arrows, callouts, shapes, freehand drawing, and looping tap indicators live on their own timeline lane. Each one has a build in and build out animation and can sit on a spotlight backdrop so it reads over a busy screen.",
    details: [
      "Drag any annotation directly on the preview",
      "Build in and build out animations per item",
      "Spotlight backdrops that dim everything behind the annotation",
    ],
  },
  {
    icon: Keyboard,
    eyebrow: "Keystroke overlay",
    title: "Show the shortcut as you press it.",
    body:
      "Turn on the overlay and every shortcut appears as a pill at the bottom of the frame, in the same timing it was pressed. Useful for keyboard heavy tutorials, and off by default so it never shows up where you did not ask for it.",
    details: [
      "Turn on Capture Shortcuts in the recording panel; only Command, Control, and Option combinations are kept",
      "Rendered by the same code in the preview and the export",
      "Pairs with synthesized key sounds if you want them",
    ],
  },
  {
    icon: Search,
    eyebrow: "Library",
    title: "Search the text inside your recordings.",
    body:
      "Every capture is indexed with on device OCR. Press Command K, type a word you remember seeing on screen, and the result jumps to that exact frame. Folders, pins, filters, and reminders keep a large library usable.",
    details: [
      "Command K search over the text in every frame",
      "Folders, pins, and filters",
      "Capture highlighted text from any app as a note with Option Command N",
    ],
  },
  {
    icon: Download,
    eyebrow: "Export",
    title: "Pick a quality, see the file size before you press go.",
    body:
      "MP4 or MOV, up to 4K at 60 fps. Quality presets show a live bitrate and file size estimate. Fast export collapses spans where nothing moved, which makes a screen recording dramatically smaller with no visible change.",
    details: [
      "4K 60 fps ceiling, Metal accelerated encoding",
      "Live bitrate and size estimate",
      "Fast export for much smaller files on static screens",
    ],
  },
  {
    icon: HardDrive,
    eyebrow: "Your own storage",
    title: "Share links that play from your own bucket.",
    body:
      "Connect an S3 compatible bucket and every shared video uploads straight to it, from the Mac app and the web recorder alike. The share page, comments, and analytics work as before, but the file never sits on our servers and never counts against your CaptureCat storage.",
    details: [
      "AWS S3, Cloudflare R2, Backblaze B2, Wasabi, and MinIO",
      "Private buckets play through short lived signed links; public buckets and CDNs play directly",
      "Keys are checked with a test upload before saving and stored encrypted. Included in Pro",
    ],
  },
];

function FeaturesPage() {
  return (
    <main className="flex min-h-screen flex-col bg-background">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(jsonLdData) }}
      />
      <Navbar />

      <section className="relative isolate overflow-hidden">
        <Ambient variant="hero" />
        <Container className="pb-12 pt-16 text-center md:pt-24">
          <Eyebrow>Features</Eyebrow>
          <h1 className="mx-auto mt-6 max-w-3xl text-balance text-5xl font-semibold leading-[1.04] tracking-[-0.03em] md:text-6xl">
            Everything CaptureCat does, on one page.
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-pretty text-lg leading-relaxed text-muted-foreground">
            The home page shows the headline features. This page shows the
            rest, followed by the complete inventory of what ships in the app
            today. Nothing on this page is planned or in beta.
          </p>
          <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <PrimaryLink to="/download">
              <AppleGlyph />
              Download for Mac
            </PrimaryLink>
            <SecondaryLink to="/" hash="features">
              Headline features
            </SecondaryLink>
          </div>
        </Container>
      </section>

      <section className="relative isolate py-8 lg:py-0">
        <Container>
          <PinnedStory
            className="ccd-fp"
            stage={
              <>
                <SceneSlot index={0}>
                  <IPhoneScene />
                </SceneSlot>
                <SceneSlot index={1}>
                  <WebCaptureScene />
                </SceneSlot>
                <SceneSlot index={2}>
                  <AnnotationsScene />
                </SceneSlot>
                <SceneSlot index={3}>
                  <KeystrokesScene />
                </SceneSlot>
                <SceneSlot index={4}>
                  <LibraryScene />
                </SceneSlot>
                <SceneSlot index={5} className="ccd-x-exportq">
                  <ExportScene quality />
                </SceneSlot>
                <SceneSlot index={6} className="ccd-x-export">
                  <ExportScene bucket="s3://acme-videos" />
                </SceneSlot>
              </>
            }
            steps={SECTIONS.map((item) => (
              <>
                <IconTile>
                  <item.icon className="h-[18px] w-[18px]" strokeWidth={1.75} />
                </IconTile>
                <p className="mt-5 text-[13px] font-medium uppercase tracking-[0.08em] text-muted-foreground">
                  {item.eyebrow}
                </p>
                <h2 className="mt-2 text-balance text-2xl font-medium tracking-[-0.02em] text-foreground md:text-3xl">
                  {item.title}
                </h2>
                <p className="mt-4 text-[15.5px] leading-relaxed text-muted-foreground">{item.body}</p>
                <ul className="mt-5 space-y-2">
                  {item.details.map((d) => (
                    <li key={d} className="flex gap-2.5 text-[14px] leading-relaxed text-muted-foreground">
                      <span aria-hidden className="mt-[8px] h-1 w-1 shrink-0 rounded-full bg-cyan-300/60" />
                      {d}
                    </li>
                  ))}
                </ul>
              </>
            ))}
          />
        </Container>
      </section>

      <FeatureInventory
        title="The complete inventory."
        muted="Grouped by where it lives in the app."
      />
      <FinalCta />
      <Footer />
    </main>
  );
}
