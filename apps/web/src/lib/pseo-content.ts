import type { SitePage } from "./site-content";
import { SITE_URL } from "./site-url";

/**
 * Programmatic SEO: one competitor record generates a comparison page
 * (/compare/capturecat-vs-{slug}) and an alternative page
 * (/alternatives/{slug}-alternative), each with HTML, a Markdown twin, FAQs,
 * and JSON-LD, all from the same data, so the renderings never drift.
 *
 * The generated pages are appended to SITE_PAGES in site-content.ts, which
 * automatically enrols them in the sitemap, llms.txt, the /*.md routes, the
 * Accept: text/markdown negotiation, and the Link: rel="alternate" headers.
 *
 * Competitor facts were checked on FACTS_CHECKED. Keep claims conservative:
 * a cell may be true, false, a short string, or null ("check their site"),
 * never guess a competitor feature we haven't verified.
 */

export const FACTS_CHECKED = "2026-08-14";
const LAST_MODIFIED = "2026-08-14";

/** A feature cell: supported / not / nuance / unverified. */
export type FeatureCell = boolean | string | null;

export interface FeatureRow {
  label: string;
  capturecat: FeatureCell;
}

/** The rows every comparison table shows, with CaptureCat's column fixed. */
export const FEATURE_ROWS: FeatureRow[] = [
  { label: "Automatic zoom & motion effects", capturecat: true },
  { label: "Cursor smoothing & click ripples", capturecat: true },
  { label: "On-device captions", capturecat: true },
  { label: "AI agent editing (built-in MCP server)", capturecat: true },
  { label: "Share links with viewer analytics", capturecat: "Pro" },
  { label: "Free version", capturecat: "Free full editor" },
  { label: "Open source", capturecat: false },
  { label: "Platform", capturecat: "macOS (native)" },
  { label: "Price", capturecat: "Free · Pro subscription" },
];

export interface Competitor {
  slug: string;
  name: string;
  website: string;
  /** One-sentence neutral description of what the product is. */
  summary: string;
  /** The honest one-liner on how CaptureCat differs. */
  differentiator: string;
  /** When the competitor is genuinely the better pick. */
  pickThemWhen: string;
  strengths: string[];
  tradeoffs: string[];
  /** Cells aligned 1:1 with FEATURE_ROWS. */
  features: FeatureCell[];
  /** How switching works, for the alternatives page. */
  switchTip: string;
  /** Optional extra FAQ specific to this competitor. */
  faqExtra?: { question: string; answer: string };
}

export const COMPETITORS: Competitor[] = [
  {
    slug: "screen-studio",
    name: "Screen Studio",
    website: "https://screen.studio",
    summary:
      "Screen Studio is a macOS screen recorder known for its automatic zoom animations and polished, Notion-style demo output.",
    differentiator:
      "Both apps add cinematic zooms automatically. CaptureCat's editor is free (Screen Studio is a paid licence with yearly update fees), and CaptureCat adds on-device captions, share links with viewer analytics, and a built-in MCP server so AI agents can edit and export your recordings.",
    pickThemWhen:
      "you want a one-time licence from a long-established tool and don't need captions, share analytics, or agent automation.",
    strengths: [
      "Pioneered the auto-zoom, smooth-cursor demo look",
      "Polished output with minimal effort",
      "One-time purchase rather than a forced subscription",
    ],
    tradeoffs: [
      "Paid licence (about $149), with updates billed yearly after the first year",
      "No free tier beyond a trial",
      "No AI-agent integration. Every edit is done by hand in the app",
    ],
    features: [
      true, // auto zoom
      true, // cursor fx
      null, // captions: unverified
      false, // MCP
      null, // share analytics: unverified
      "Trial only",
      false,
      "macOS",
      "~$149 one-time + yearly updates",
    ],
    switchTip:
      "Record in CaptureCat exactly as you did in Screen Studio. The zooms, cursor smoothing, and click ripples are applied automatically the same way, and your first project costs nothing.",
    faqExtra: {
      question: "Is CaptureCat cheaper than Screen Studio?",
      answer:
        "CaptureCat's recorder and full editor are free forever, including automatic zooms, cursor smoothing, captions, and full-quality export. Screen Studio is a paid licence (about $149) with yearly update fees. CaptureCat's paid tier (Pro) only covers cloud features: share links, comments, and viewer analytics.",
    },
  },
  {
    slug: "cap",
    name: "Cap",
    website: "https://cap.so",
    summary:
      "Cap is an open-source screen recorder for macOS and Windows focused on instant recording and one-click share links, with optional self-hosting.",
    differentiator:
      "Cap's core is instant capture-and-share; CaptureCat's core is automatic cinematography. It replays your session and adds zooms, cursor smoothing, and captions by itself, then exports a file that matches the preview frame-for-frame. CaptureCat also ships a built-in MCP server for AI-agent editing.",
    pickThemWhen:
      "you want an open-source, cross-platform recorder you can self-host, and raw speed-to-link matters more than automatic editing.",
    strengths: [
      "Open source with a self-hosting option",
      "Runs on both macOS and Windows",
      "Generous free Studio mode and instant share links",
    ],
    tradeoffs: [
      "Automatic cinematography is not the product's centre of gravity",
      "Cloud features sit behind a paid plan",
      "No AI-agent integration",
    ],
    features: [
      null, // auto zoom: unverified depth
      null,
      null,
      false,
      true,
      "Free Studio mode",
      true,
      "macOS & Windows",
      "Free (open source) · paid cloud",
    ],
    switchTip:
      "Keep Cap for quick throwaway links if you like it. CaptureCat earns its place on the recordings that need to look produced: product demos, launch videos, and tutorials where zooms and captions matter.",
  },
  {
    slug: "loom",
    name: "Loom",
    website: "https://www.loom.com",
    summary:
      "Loom (an Atlassian product) is an async video-messaging tool for teams: record a quick clip in the browser or desktop app and send a link.",
    differentiator:
      "Loom optimises for speed of communication; the recording itself stays raw. CaptureCat optimises for how the recording looks (automatic zooms, a steadied cursor, on-device captions, device frames) while still giving you share links, timestamped comments, and viewer analytics.",
    pickThemWhen:
      "your team already lives in Loom and the videos are quick internal messages nobody needs to polish.",
    strengths: [
      "Ubiquitous for async team updates",
      "Records from the browser and on every platform",
      "Transcripts and team workspace features",
    ],
    tradeoffs: [
      "Recordings look raw. No automatic zooms or cursor work",
      "Free tier caps videos at 5 minutes and 25 videos",
      "Per-seat subscription pricing adds up for teams",
    ],
    features: [
      false,
      false,
      true,
      false,
      true,
      "5-min / 25-video cap",
      false,
      "macOS, Windows, web, mobile",
      "Free tier · per-seat subscription",
    ],
    switchTip:
      "CaptureCat's share links work the way Loom's do, public or private with comments pinned to the exact second, so the sharing workflow carries over; the videos just arrive already edited.",
  },
  {
    slug: "cleanshot-x",
    name: "CleanShot X",
    website: "https://cleanshot.com",
    summary:
      "CleanShot X is a macOS capture utility: best-in-class screenshots and quick screen recordings with annotation and cloud links.",
    differentiator:
      "CleanShot X is a capture utility first; video is one of many tools in it. CaptureCat is a video product: it captures clicks and keystrokes as data, then automatically produces the zooms, cursor smoothing, and captions a polished demo needs, with viewer analytics on every share link.",
    pickThemWhen:
      "screenshots and annotations are your daily driver and screen video is an occasional, keep-it-raw need.",
    strengths: [
      "Fastest screenshot-to-share workflow on macOS",
      "Excellent annotation tools",
      "Affordable one-time base licence",
    ],
    tradeoffs: [
      "Not built for polished demo videos. No automatic zooms or cursor effects",
      "No viewer analytics on shared media",
      "No AI-agent integration",
    ],
    features: [
      false,
      "Click highlights",
      false,
      false,
      "Links, no analytics",
      "Trial only",
      false,
      "macOS",
      "One-time licence · optional cloud",
    ],
    switchTip:
      "Many people run both: CleanShot X for screenshots, CaptureCat for anything that moves. CaptureCat Pro also uploads screenshots and captures web pages by URL if you'd rather consolidate.",
  },
  {
    slug: "obs-studio",
    name: "OBS Studio",
    website: "https://obsproject.com",
    summary:
      "OBS Studio is the free, open-source capture and live-streaming powerhouse used across macOS, Windows, and Linux.",
    differentiator:
      "OBS records anything but edits nothing. Output needs a separate editor and real skill. CaptureCat trades OBS's infinite configurability for a finished result: by the time you stop recording, the zooms, cursor smoothing, and captions are already applied.",
    pickThemWhen:
      "you're live-streaming, compositing scenes, or need capture flexibility no consumer app offers, and you're happy editing afterwards.",
    strengths: [
      "Completely free and open source",
      "Unmatched capture and streaming flexibility",
      "Huge plugin ecosystem",
    ],
    tradeoffs: [
      "Steep learning curve",
      "No editing. Raw footage needs a separate editor",
      "No sharing, analytics, or automatic polish of any kind",
    ],
    features: [
      false,
      false,
      false,
      false,
      false,
      "Completely free",
      true,
      "macOS, Windows, Linux",
      "Free",
    ],
    switchTip:
      "If OBS is your recorder because it's free, note that CaptureCat's recorder and editor are also free. The difference is you skip the editing session afterwards.",
  },
  {
    slug: "camtasia",
    name: "Camtasia",
    website: "https://www.techsmith.com/camtasia",
    summary:
      "Camtasia (TechSmith) is a full manual screen-recording and video-editing suite for macOS and Windows, popular for courseware and training videos.",
    differentiator:
      "Camtasia gives you a multitrack timeline and expects you to drive it. Zooms, cursor effects, and callouts are all placed by hand. CaptureCat derives them automatically from your recorded clicks and keystrokes, and an AI agent can adjust them over MCP.",
    pickThemWhen:
      "you're producing long-form courseware with quizzes, chapters, and heavy manual editing.",
    strengths: [
      "Full manual multitrack editor",
      "Quizzes, templates, and courseware features",
      "Long track record on both macOS and Windows",
    ],
    tradeoffs: [
      "Every zoom and cursor effect is manual keyframe work",
      "Heavyweight app with a paid subscription",
      "No automatic cinematography or agent workflow",
    ],
    features: [
      "Manual keyframes",
      "Manual effects",
      true,
      false,
      null,
      "Trial only",
      false,
      "macOS & Windows",
      "Paid subscription",
    ],
    switchTip:
      "For the demos you used to hand-edit in Camtasia, record in CaptureCat and check the timeline afterwards. The zooms it placed from your click data are usually the ones you'd have keyframed yourself.",
  },
  {
    slug: "kap",
    name: "Kap",
    website: "https://getkap.co",
    summary:
      "Kap is a small, free, open-source menu-bar screen recorder for macOS with quick exports to MP4 and GIF.",
    differentiator:
      "Kap captures and exports. That is its whole (charming) job. CaptureCat also captures from the menu bar, but then does the editing for you: automatic zooms, cursor smoothing, captions, wallpapers, and device frames, with share links and analytics when you want them.",
    pickThemWhen:
      "you need a tiny free tool for quick raw GIFs and clips, and polish doesn't matter.",
    strengths: [
      "Free and open source",
      "Tiny, simple, lives in the menu bar",
      "Handy GIF export and plugins",
    ],
    tradeoffs: [
      "No editing, effects, or captions",
      "No sharing or analytics",
      "Development moves slowly",
    ],
    features: [
      false,
      false,
      false,
      false,
      false,
      "Completely free",
      true,
      "macOS",
      "Free",
    ],
    switchTip:
      "CaptureCat's free tier covers everything Kap does, plus the automatic editing, so switching costs nothing; your quick clips just stop looking quick.",
  },
  {
    slug: "quicktime",
    name: "QuickTime Player",
    website: "https://support.apple.com/guide/quicktime-player",
    summary:
      "QuickTime Player is macOS's built-in recorder. Press ⇧⌘5 and capture the screen with no extra software.",
    differentiator:
      "QuickTime gives you the raw pixels and stops there. CaptureCat records the same screen but also captures every click and keystroke as data, then turns that into cinematic zooms, a steadied cursor, and on-device captions. Automatically, and still free.",
    pickThemWhen:
      "you need a one-off raw capture right now and don't want to install anything.",
    strengths: [
      "Already installed on every Mac",
      "Zero setup, zero cost",
      "Fine for quick raw grabs",
    ],
    tradeoffs: [
      "No editing, zooms, captions, or cursor effects",
      "No system-audio capture without extra software",
      "No sharing links or analytics",
    ],
    features: [
      false,
      false,
      false,
      false,
      false,
      "Built into macOS",
      false,
      "macOS (built-in)",
      "Free with macOS",
    ],
    switchTip:
      "CaptureCat is the upgrade path from ⇧⌘5: the recording flow is just as fast, the app is free, and the result comes out looking edited instead of raw.",
  },
];

/* ------------------------------------------------------------------ */
/* Derived page data                                                   */
/* ------------------------------------------------------------------ */

export interface Faq {
  question: string;
  answer: string;
}

export interface PseoPage {
  kind: "compare" | "alternative";
  competitor: Competitor;
  path: string;
  title: string;
  heroTitle: string;
  heroSubtitle: string;
  description: string;
  faqs: Faq[];
}

export function comparePath(c: Competitor): string {
  return `/compare/capturecat-vs-${c.slug}`;
}

export function alternativePath(c: Competitor): string {
  return `/alternatives/${c.slug}-alternative`;
}

function compareFaqs(c: Competitor): Faq[] {
  const faqs: Faq[] = [
    {
      question: `What is the main difference between CaptureCat and ${c.name}?`,
      answer: c.differentiator,
    },
    {
      question: "Is CaptureCat free?",
      answer:
        "Yes. The recorder and the full editor are free forever, including automatic zooms, cursor smoothing, on-device captions, and full-quality export. The Pro subscription only adds cloud features: share links, timestamped comments, and viewer analytics.",
    },
    {
      question: `Does ${c.name} work with AI agents?`,
      answer: `Not over an open protocol that we know of. CaptureCat ships a Model Context Protocol (MCP) server inside the app, so Claude, ChatGPT, Cursor, Copilot, or Windsurf can inspect a recording, add zooms where you clicked, restyle the frame, and export the final video with the same engine the editor uses.`,
    },
    {
      question: `When is ${c.name} the better choice?`,
      answer: `Pick ${c.name} when ${c.pickThemWhen}`,
    },
  ];
  if (c.faqExtra) faqs.push(c.faqExtra);
  return faqs;
}

function alternativeFaqs(c: Competitor): Faq[] {
  return [
    {
      question: `What is a good ${c.name} alternative for Mac?`,
      answer: `CaptureCat is a native Mac screen recorder that edits itself: automatic cinematic zooms, cursor smoothing, on-device captions, and device frames, with share links and viewer analytics on the Pro plan. ${c.differentiator}`,
    },
    {
      question: "Is CaptureCat free?",
      answer:
        "Yes. The recorder and the full editor are free forever. Pro adds cloud sharing, timestamped comments, and viewer analytics.",
    },
    {
      question: `How do I switch from ${c.name} to CaptureCat?`,
      answer: c.switchTip,
    },
  ];
}

export function buildPseoPage(
  kind: "compare" | "alternative",
  c: Competitor
): PseoPage {
  if (kind === "compare") {
    return {
      kind,
      competitor: c,
      path: comparePath(c),
      title: `CaptureCat vs ${c.name}`,
      heroTitle: `CaptureCat vs ${c.name}`,
      heroSubtitle: c.differentiator,
      description: `CaptureCat vs ${c.name} for Mac screen recording: features, pricing, automatic editing, AI-agent support, and when to pick each. Facts checked ${FACTS_CHECKED}.`,
      faqs: compareFaqs(c),
    };
  }
  return {
    kind,
    competitor: c,
    path: alternativePath(c),
    title: `${c.name} Alternative for Mac`,
    heroTitle: `The ${c.name} alternative that edits itself`,
    heroSubtitle: `${c.summary} If you're after something different, CaptureCat records your Mac and applies the editing automatically (zooms, cursor smoothing, captions), then shares a link with viewer analytics.`,
    description: `Looking for a ${c.name} alternative on macOS? CaptureCat is a free native screen recorder with automatic cinematic zooms, on-device captions, AI-agent editing over MCP, and share links with analytics.`,
    faqs: alternativeFaqs(c),
  };
}

export const PSEO_COMPARE_PAGES: PseoPage[] = COMPETITORS.map((c) =>
  buildPseoPage("compare", c)
);
export const PSEO_ALTERNATIVE_PAGES: PseoPage[] = COMPETITORS.map((c) =>
  buildPseoPage("alternative", c)
);

export function findPseoPage(path: string): PseoPage | undefined {
  return [...PSEO_COMPARE_PAGES, ...PSEO_ALTERNATIVE_PAGES].find(
    (p) => p.path === path
  );
}

/* ------------------------------------------------------------------ */
/* Markdown twins                                                      */
/* ------------------------------------------------------------------ */

export function cellText(cell: FeatureCell): string {
  if (cell === true) return "✓";
  if (cell === false) return "No";
  if (cell === null) return "check their site";
  return cell;
}

function markdownTable(c: Competitor): string {
  const header = `| Feature | CaptureCat | ${c.name} |\n| --- | --- | --- |`;
  const rows = FEATURE_ROWS.map(
    (row, i) =>
      `| ${row.label} | ${cellText(row.capturecat)} | ${cellText(c.features[i])} |`
  );
  return [header, ...rows].join("\n");
}

function markdownFaqs(faqs: Faq[]): string {
  return faqs.map((f) => `### ${f.question}\n\n${f.answer}`).join("\n\n");
}

function pageMarkdown(page: PseoPage): string {
  const c = page.competitor;
  const lists = `## Where ${c.name} shines\n\n${c.strengths
    .map((s) => `- ${s}`)
    .join("\n")}\n\n## Trade-offs\n\n${c.tradeoffs
    .map((t) => `- ${t}`)
    .join("\n")}`;
  return `# ${page.heroTitle}

${page.heroSubtitle}

## Side by side

${markdownTable(c)}

_Competitor details checked ${FACTS_CHECKED}; see [${c.name}'s site](${c.website}) for current pricing and features._

${lists}

## FAQ

${markdownFaqs(page.faqs)}

---

[Download CaptureCat for Mac](${SITE_URL}/download) · [Pricing](${SITE_URL}/pricing) · [All comparisons](${SITE_URL}/compare)
`;
}

/* ------------------------------------------------------------------ */
/* JSON-LD                                                             */
/* ------------------------------------------------------------------ */

/** The canonical CaptureCat SoftwareApplication node, reused across pages. */
export function captureCatJsonLd() {
  return {
    "@type": "SoftwareApplication",
    "@id": `${SITE_URL}/#app`,
    name: "CaptureCat",
    operatingSystem: "macOS",
    applicationCategory: "MultimediaApplication",
    description:
      "A native screen recorder for Mac that edits itself: automatic cinematic zooms, cursor smoothing, on-device captions, device frames, and share links with viewer analytics.",
    url: SITE_URL,
    downloadUrl: `${SITE_URL}/download`,
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  };
}

export function pseoJsonLd(page: PseoPage): object {
  const c = page.competitor;
  const url = `${SITE_URL}${page.path}`;
  const crumbs = [
    { name: "Home", item: SITE_URL },
    page.kind === "compare"
      ? { name: "Compare", item: `${SITE_URL}/compare` }
      : { name: "Alternatives", item: `${SITE_URL}/compare` },
    { name: page.title, item: url },
  ];
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "WebPage",
        "@id": url,
        name: page.title,
        description: page.description,
        url,
        dateModified: LAST_MODIFIED,
        breadcrumb: { "@id": `${url}#breadcrumb` },
        about: { "@id": `${SITE_URL}/#app` },
      },
      {
        "@type": "BreadcrumbList",
        "@id": `${url}#breadcrumb`,
        itemListElement: crumbs.map((crumb, i) => ({
          "@type": "ListItem",
          position: i + 1,
          name: crumb.name,
          item: crumb.item,
        })),
      },
      {
        "@type": "FAQPage",
        "@id": `${url}#faq`,
        mainEntity: page.faqs.map((f) => ({
          "@type": "Question",
          name: f.question,
          acceptedAnswer: { "@type": "Answer", text: f.answer },
        })),
      },
      captureCatJsonLd(),
      {
        "@type": "SoftwareApplication",
        name: c.name,
        url: c.website,
        applicationCategory: "MultimediaApplication",
      },
    ],
  };
}

/* ------------------------------------------------------------------ */
/* Registry entries (consumed by site-content.ts)                      */
/* ------------------------------------------------------------------ */

const hubMarkdown = `# Compare Mac Screen Recorders

How CaptureCat stacks up against other Mac screen recorders, feature by
feature, with honest trade-offs and a note on when the other tool is the
better pick. Competitor details checked ${FACTS_CHECKED}.

## Comparisons

${PSEO_COMPARE_PAGES.map(
  (p) => `- [${p.title}](${SITE_URL}${p.path}): ${p.competitor.summary}`
).join("\n")}

## Alternatives

${PSEO_ALTERNATIVE_PAGES.map(
  (p) => `- [${p.title}](${SITE_URL}${p.path})`
).join("\n")}

[Download CaptureCat for Mac](${SITE_URL}/download) · [Pricing](${SITE_URL}/pricing)
`;

export const PSEO_SITE_PAGES: SitePage[] = [
  {
    path: "/compare",
    title: "Compare Mac Screen Recorders",
    description:
      "How CaptureCat compares to Screen Studio, Cap, Loom, CleanShot X, OBS, Camtasia, Kap, and QuickTime: features, pricing, and honest trade-offs.",
    lastModified: LAST_MODIFIED,
    markdown: hubMarkdown,
  },
  ...[...PSEO_COMPARE_PAGES, ...PSEO_ALTERNATIVE_PAGES].map((page) => ({
    path: page.path,
    title: page.title,
    description: page.description,
    lastModified: LAST_MODIFIED,
    markdown: pageMarkdown(page),
  })),
];
