import type { SitePage } from "./site-content";
import { SITE_URL } from "./site-url";
import { COMPETITORS } from "./competitors";

export { COMPETITORS };

/**
 * Programmatic SEO: one competitor record generates a comparison page
 * (/compare/capturecat-vs-{slug}) and an alternative page
 * (/alternatives/{slug}-alternative), each with HTML, a Markdown twin, FAQs,
 * and JSON-LD, all from the same data, so the renderings never drift.
 *
 * The generated pages are appended to SITE_PAGES in site-content.ts, which
 * automatically enrols them in the sitemap, llms.txt, the /*.md routes, and
 * the Link: rel="alternate" headers.
 *
 * Competitor records live in competitors.ts. Every non-null cell there was
 * checked against the competitor's own site on FACTS_CHECKED and carries its
 * source URLs. A cell may be true, false, a short string, or null ("check
 * their site"); never guess a competitor feature nobody has verified.
 */

export const FACTS_CHECKED = "2026-10-06";
const LAST_MODIFIED = "2026-10-06";

/** A feature cell: supported / not / nuance / unverified. */
export type FeatureCell = boolean | string | null;

export interface FeatureRow {
  label: string;
  /** Short header for the all-recorders matrix on /compare. */
  short: string;
  capturecat: FeatureCell;
}

/**
 * The rows every comparison table shows, with CaptureCat's column fixed.
 * Every CaptureCat cell must stay true of the shipping app (see
 * feature-inventory.ts and platforms.ts).
 */
export const FEATURE_ROWS: FeatureRow[] = [
  { label: "Automatic zoom from clicks", short: "Auto zoom", capturecat: true },
  { label: "Cursor smoothing & click effects", short: "Cursor", capturecat: true },
  { label: "Auto captions", short: "Captions", capturecat: "On-device (English)" },
  { label: "AI agent editing (MCP server)", short: "MCP", capturecat: "Built in, 28 tools" },
  { label: "Share links with viewer analytics", short: "Share analytics", capturecat: "Pro" },
  { label: "Free version", short: "Free tier", capturecat: "Full editor, no watermark" },
  { label: "Open source", short: "Open source", capturecat: "AGPL-3.0" },
  {
    label: "Platform",
    short: "Platform",
    capturecat: "macOS (native) · browser on Windows, Linux, ChromeOS",
  },
  { label: "Price", short: "Price", capturecat: "Free · Pro subscription" },
];

/** Index of the MCP row in FEATURE_ROWS / Competitor.features. */
const MCP_ROW = 3;

export type CompetitorCategory =
  | "demo"
  | "async"
  | "editor"
  | "capture"
  | "free"
  | "interactive";

export const CATEGORY_LABELS: Record<CompetitorCategory, string> = {
  demo: "Auto-zoom demo recorders",
  async: "Async video and share links",
  editor: "Recorders with a full video editor",
  capture: "Screenshot and capture utilities",
  free: "Free, open source, and built in",
  interactive: "AI product videos and interactive demos",
};

export interface Competitor {
  slug: string;
  name: string;
  website: string;
  category: CompetitorCategory;
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
  /** Where the facts came from (the competitor's own pages first). */
  sources: string[];
}


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
  /** The <title> (registry seoTitle); `title` stays the short link label. */
  seoTitle: string;
  heroTitle: string;
  heroSubtitle: string;
  description: string;
  faqs: Faq[];
}

/**
 * The name without qualifiers, for titles and descriptions:
 * "QuickTime Player / macOS Screenshot (⇧⌘5)" → "QuickTime Player".
 */
export function shortName(c: Competitor): string {
  return c.name.split(" / ")[0].split(" (")[0].trim();
}

const YEAR = FACTS_CHECKED.slice(0, 4);

/** The first candidate that fits a search result title (~65 chars). */
function fitTitle(...candidates: string[]): string {
  return candidates.find((t) => t.length <= 65) ?? candidates[candidates.length - 1];
}

export function comparePath(c: Competitor): string {
  return `/compare/capturecat-vs-${c.slug}`;
}

export function alternativePath(c: Competitor): string {
  return `/alternatives/${c.slug}-alternative`;
}

/** What we verified about the competitor's agent support, from its MCP cell. */
function agentAnswer(c: Competitor): string {
  const cell = c.features[MCP_ROW];
  if (cell === true) return `Yes. ${c.name} offers an official MCP server.`;
  if (typeof cell === "string") return `As of ${FACTS_CHECKED}: ${cell}.`;
  if (cell === false)
    return `Not that we could find: as of ${FACTS_CHECKED}, ${c.name} has no official MCP server.`;
  return `We could not confirm either way; check ${c.name}'s site.`;
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
      answer: `${agentAnswer(c)} CaptureCat ships a Model Context Protocol (MCP) server inside the app, so Claude, Codex, Cursor, Copilot, or Windsurf can inspect a recording, add zooms where you clicked, restyle the frame, and export the final video with the same engine the editor uses.`,
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
  const name = shortName(c);
  if (kind === "compare") {
    return {
      kind,
      competitor: c,
      path: comparePath(c),
      title: `CaptureCat vs ${name}`,
      seoTitle: fitTitle(
        `CaptureCat vs ${name}: features and pricing (${YEAR})`,
        `CaptureCat vs ${name} (${YEAR})`
      ),
      heroTitle: `CaptureCat vs ${c.name}`,
      heroSubtitle: c.differentiator,
      description: `CaptureCat vs ${name}: auto zoom, captions, AI-agent support, sharing, and price compared, with sources. Checked ${FACTS_CHECKED}.`,
      faqs: compareFaqs(c),
    };
  }
  return {
    kind,
    competitor: c,
    path: alternativePath(c),
    title: `${name} Alternative for Mac`,
    seoTitle: fitTitle(
      `${name} alternative for Mac (${YEAR}) | CaptureCat`,
      `${name} alternative for Mac (${YEAR})`
    ),
    heroTitle: `The ${c.name} alternative that edits itself`,
    heroSubtitle: `${c.summary} If you're after something different, CaptureCat records your Mac and applies the editing automatically (zooms, cursor smoothing, captions), then shares a link with viewer analytics.`,
    description: `Looking for a ${name} alternative on Mac? CaptureCat is a free, open-source recorder with auto zoom, on-device captions, and AI-agent editing.`,
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

Sources: ${c.sources.map((u) => `<${u}>`).join(", ")}

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

/** Competitors grouped by category, in CATEGORY_LABELS order. */
export function competitorsByCategory(): Array<[CompetitorCategory, Competitor[]]> {
  return (Object.keys(CATEGORY_LABELS) as CompetitorCategory[])
    .map((cat) => [cat, COMPETITORS.filter((c) => c.category === cat)] as [CompetitorCategory, Competitor[]])
    .filter(([, list]) => list.length > 0);
}

function matrixMarkdown(): string {
  const header = `| Recorder | ${FEATURE_ROWS.map((r) => r.short).join(" | ")} |`;
  const rule = `| --- | ${FEATURE_ROWS.map(() => "---").join(" | ")} |`;
  const row = (name: string, cells: FeatureCell[]) =>
    `| ${name} | ${cells.map(cellText).join(" | ")} |`;
  return [
    header,
    rule,
    row("**CaptureCat**", FEATURE_ROWS.map((r) => r.capturecat)),
    ...COMPETITORS.map((c) => row(`[${c.name}](${SITE_URL}${comparePath(c)})`, c.features)),
  ].join("\n");
}

const hubMarkdown = `# Compare screen recorders

${COMPETITORS.length} screen recorders compared with CaptureCat, feature by
feature, with honest trade-offs and a note on when the other tool is the
better pick. Every competitor detail was checked against that product's own
site on ${FACTS_CHECKED}; each comparison page lists its sources.

## All recorders at a glance

${matrixMarkdown()}

"check their site" means we could not verify the feature either way.

${competitorsByCategory()
  .map(
    ([cat, list]) =>
      `## ${CATEGORY_LABELS[cat]}\n\n${list
        .map((c) => `- [CaptureCat vs ${c.name}](${SITE_URL}${comparePath(c)}): ${c.summary}`)
        .join("\n")}`
  )
  .join("\n\n")}

## Best-of lists

- [Best screen recorders for Mac](${SITE_URL}/best/screen-recorder-for-mac)
- [Best free screen recorders for Mac](${SITE_URL}/best/free-screen-recorder-for-mac)
- [Best Screen Studio alternatives](${SITE_URL}/best/screen-studio-alternatives)
- [Best Loom alternatives](${SITE_URL}/best/loom-alternatives)
- [Best open source screen recorders](${SITE_URL}/best/open-source-screen-recorders)
- [Screen recorders with automatic zoom](${SITE_URL}/best/auto-zoom-screen-recorders)
- [Best tools for product demo videos](${SITE_URL}/best/screen-recorder-for-product-demos)
- [Screen recorders AI agents can use](${SITE_URL}/best/screen-recorders-for-ai-agents)
- [Best screen recorders for Windows](${SITE_URL}/best/screen-recorder-for-windows)

## Alternatives

${PSEO_ALTERNATIVE_PAGES.map(
  (p) => `- [${p.title}](${SITE_URL}${p.path})`
).join("\n")}

[Download CaptureCat for Mac](${SITE_URL}/download) · [Pricing](${SITE_URL}/pricing)
`;

export const COMPARE_HUB_DESCRIPTION = `${COMPETITORS.length} screen recorders compared with CaptureCat: auto zoom, captions, AI-agent support, sharing, platform, and price. Sourced and dated.`;

export const PSEO_SITE_PAGES: SitePage[] = [
  {
    path: "/compare",
    title: "Compare Screen Recorders",
    seoTitle: `Compare ${COMPETITORS.length} screen recorders side by side | CaptureCat`,
    description: COMPARE_HUB_DESCRIPTION,
    lastModified: LAST_MODIFIED,
    markdown: hubMarkdown,
  },
  ...[...PSEO_COMPARE_PAGES, ...PSEO_ALTERNATIVE_PAGES].map((page) => ({
    path: page.path,
    title: page.title,
    seoTitle: page.seoTitle,
    description: page.description,
    lastModified: LAST_MODIFIED,
    markdown: pageMarkdown(page),
  })),
];
