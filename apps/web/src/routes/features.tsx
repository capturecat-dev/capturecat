import { Link, createFileRoute } from "@tanstack/react-router";
import {
  Monitor,
  Sparkles,
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
import FeatureInventory from "@/components/marketing/FeatureInventory";
import { AirPage, AirPageHero } from "@/components/marketing/airy/Page";
import { AirFinalCta } from "@/components/marketing/airy/Sections";
import {
  AirChecks,
  AirContainer,
  AirLede,
  AirPill,
  AirTitle,
  GHOST_ON_DARK,
  InkLink,
  SoftLink,
} from "@/components/marketing/airy/primitives";
import { AppleGlyph } from "@/components/marketing/primitives";
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
import airyCss from "@/styles/airy.css?url";

export const Route = createFileRoute("/features")({
  head: () =>
    pageHead("/features", [
      { rel: "stylesheet", href: demosCss },
      { rel: "stylesheet", href: demosPagesCss },
      { rel: "stylesheet", href: airyCss },
    ]),
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
      "Connect an iPhone or iPad over USB and it shows up as a source next to your displays and windows. The export wraps an iPhone recording in a phone bezel with a Dynamic Island (an iPad gets a thin frame), sitting on whatever background you chose.",
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
      "Capture highlighted text from any app as a note from the Services menu",
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
      "Connect an S3 compatible bucket and every video you share uploads straight to it, whether you share from the Mac app or the web editor. The share page, comments, and analytics work as before, but the file never sits on our servers and never counts against your CaptureCat storage.",
    details: [
      "AWS S3, Cloudflare R2, Backblaze B2, Wasabi, and MinIO",
      "Private buckets play through short lived signed links; public buckets and CDNs play directly",
      "Keys are checked with a test upload before saving and stored encrypted. Included in Pro",
    ],
  },
];

function FeaturesPage() {
  return (
    <AirPage>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd(jsonLdData) }}
      />
      <AirPageHero
        pill="Features"
        icon={<Sparkles className="h-3.5 w-3.5" strokeWidth={2} />}
        title="Everything CaptureCat does, on one page."
        lede="The home page shows the headline features. Here is the rest, then the complete inventory of what ships in the app today. Nothing on this page is planned or in beta."
      >
        <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <InkLink to="/download">
            <AppleGlyph />
            Download for Mac
          </InkLink>
          <SoftLink to="/" hash="zoom">
            Headline features
          </SoftLink>
        </div>
      </AirPageHero>

      <section className="relative isolate pb-8 lg:pb-0">
        <AirContainer>
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
              <div>
                <AirPill icon={<item.icon className="h-3.5 w-3.5" strokeWidth={2} />}>{item.eyebrow}</AirPill>
                <AirTitle className="mt-5 !text-[28px] md:!text-[36px]">{item.title}</AirTitle>
                <AirLede className="mt-4 !text-[16px]">{item.body}</AirLede>
                <AirChecks items={item.details} />
              </div>
            ))}
          />
        </AirContainer>
      </section>

      <FeatureInventory
        title="The complete inventory."
        muted="Grouped by where it lives in the app."
      />
      <AirFinalCta
        title="Record one thing today and see what comes out."
        lede="Free for personal use, no account to make, and your first export is ready about a minute after you stop recording."
        secondary={
          <Link to="/pricing" className={GHOST_ON_DARK}>
            See pricing
          </Link>
        }
      />
    </AirPage>
  );
}
