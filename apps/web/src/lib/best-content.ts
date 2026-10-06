import type { SitePage } from "./site-content";
import {
  COMPETITORS,
  FACTS_CHECKED,
  FEATURE_ROWS,
  captureCatJsonLd,
  cellText,
  comparePath,
  type Competitor,
  type FeatureCell,
} from "./pseo-content";
import { SITE_URL } from "./site-url";

/**
 * "Best X" lists: /best/{slug}.
 *
 * Generated from the same sourced competitor records as the comparison
 * pages, so a list can never contradict a table. Ranking is mechanical and
 * stated on the page: entries are ordered by how many of the list's criteria
 * rows they verifiably meet, then by how many of the first five feature rows
 * they meet overall. CaptureCat's own position is chosen per list and always
 * disclosed; on lists where it is the weaker fit (Windows) it goes last.
 */

/** Row indices into FEATURE_ROWS / Competitor.features. */
const ROW = {
  autoZoom: 0,
  cursor: 1,
  captions: 2,
  mcp: 3,
  share: 4,
  free: 5,
  openSource: 6,
  platform: 7,
  price: 8,
} as const;

export interface BestList {
  slug: string;
  title: string;
  /** Meta description. */
  description: string;
  /** What the reader is trying to do; one or two sentences. */
  intro: string;
  /** How entries qualify, in plain words (shown as "How we picked"). */
  criteriaText: string;
  include: (c: Competitor) => boolean;
  /** Rows that rank entries for this list. */
  criteria: number[];
  /** Where CaptureCat sits, and the note shown under it. */
  capturecat: {
    position: "first" | "last";
    note: string;
    /** Cells that differ from FEATURE_ROWS for this list's context. */
    cells?: Partial<Record<number, FeatureCell>>;
  };
  lastModified: string;
}

function truthy(cell: FeatureCell): boolean {
  if (cell === true) return true;
  if (typeof cell !== "string") return false;
  // A nuance string counts only when it affirms the feature: "Manual zoom
  // only" is not automatic zoom, "No free tier" is not a free tier.
  const t = cell.trim();
  return !/^(no\b|none|not\b|manual|n\/a|trial)/i.test(t) && !/coming soon/i.test(t);
}

function text(cell: FeatureCell): string {
  return typeof cell === "string" ? cell : "";
}

const runsOnMac = (c: Competitor) => /mac|browser|chrome|web/i.test(text(c.features[ROW.platform]));
const runsOnWindows = (c: Competitor) =>
  /windows|browser|chrome|web/i.test(text(c.features[ROW.platform]));
/** A free tier you can keep using: not a trial, and export isn't paywalled. */
function isRealFreeTier(cell: FeatureCell): boolean {
  const free = text(cell);
  return /^(fully )?free\b/i.test(free) && !/trial|to try|needs (a )?licen[cs]e|needs a plan/i.test(free);
}
const hasRealFreeTier = (c: Competitor) => isRealFreeTier(c.features[ROW.free]);

export const BEST_LISTS: BestList[] = [
  {
    slug: "screen-recorder-for-mac",
    title: "Best screen recorders for Mac",
    description:
      "The best screen recorders for macOS, compared on automatic zoom, cursor effects, captions, sharing, AI-agent support, and price. Every fact sourced.",
    intro:
      "Every Mac can record its screen with ⇧⌘5. These are the apps worth installing when you need more than raw pixels: automatic editing, captions, sharing, or a full editor.",
    criteriaText:
      "Runs on macOS (natively or in a browser). Ranked by automatic zoom, cursor effects, captions, share analytics, and a usable free tier.",
    include: runsOnMac,
    criteria: [ROW.autoZoom, ROW.cursor, ROW.captions, ROW.share, ROW.free],
    capturecat: {
      position: "first",
      note: "Native Mac app with automatic zoom from your clicks, cursor smoothing, and on-device captions, all free. Share links with analytics on Pro.",
    },
    lastModified: FACTS_CHECKED,
  },
  {
    slug: "free-screen-recorder-for-mac",
    title: "Best free screen recorders for Mac",
    description:
      "Free Mac screen recorders that are actually free to use, not just a trial: what each free tier includes and where the limits are.",
    intro:
      "Plenty of recorders call themselves free and then cap the length, add a watermark, or lock export. This list only includes products with a free tier you can keep using, and says what the limits are.",
    criteriaText:
      "Runs on macOS and has an ongoing free tier (trials excluded). Ranked by what the free tier includes.",
    include: (c) => runsOnMac(c) && hasRealFreeTier(c),
    criteria: [ROW.free, ROW.autoZoom, ROW.cursor, ROW.captions, ROW.openSource],
    capturecat: {
      position: "first",
      note: "Recording, the full editor, automatic zoom, captions, and 4K export are free with no watermark and no time limit.",
    },
    lastModified: FACTS_CHECKED,
  },
  {
    slug: "screen-studio-alternatives",
    title: "Best Screen Studio alternatives",
    description:
      "Screen recorders that add automatic zooms and smooth cursor movement like Screen Studio, compared on price, captions, sharing, and platform.",
    intro:
      "Screen Studio made the auto-zoom, smooth-cursor demo look popular. These tools produce a similar result, some for free, some on Windows or in the browser.",
    criteriaText:
      "Automatic zoom or a demo-video focus. Ranked by automatic zoom, cursor effects, captions, free tier, and sharing.",
    include: (c) =>
      c.slug !== "screen-studio" &&
      (c.category === "demo" || c.features[ROW.autoZoom] === true),
    criteria: [ROW.autoZoom, ROW.cursor, ROW.captions, ROW.free, ROW.share],
    capturecat: {
      position: "first",
      note: "Automatic zoom from recorded clicks and cursor smoothing like Screen Studio, with on-device captions and a free full editor.",
    },
    lastModified: FACTS_CHECKED,
  },
  {
    slug: "loom-alternatives",
    title: "Best Loom alternatives",
    description:
      "Screen recorders with share links and viewer analytics like Loom, compared on editing, captions, price, and platform.",
    intro:
      "Loom made recording a quick video and sending a link normal. These tools also give you a link, some with better editing, lower prices, or self-hosting.",
    criteriaText:
      "Hosted share links. Ranked by share analytics, captions, free tier, automatic zoom, and cursor effects.",
    include: (c) =>
      c.slug !== "loom" && (c.category === "async" || truthy(c.features[ROW.share])),
    criteria: [ROW.share, ROW.captions, ROW.free, ROW.autoZoom, ROW.cursor],
    capturecat: {
      position: "first",
      note: "Share links with timestamped comments and views, watch time, and retention on Pro, plus a free editor that adds zooms and captions before you share.",
    },
    lastModified: FACTS_CHECKED,
  },
  {
    slug: "open-source-screen-recorders",
    title: "Best open source screen recorders",
    description:
      "Open source screen recorders you can inspect, build, or self-host, with their licences, platforms, and features compared.",
    intro:
      "Open source matters if you want to audit what a recorder does with your screen, build it yourself, or host the sharing side on your own servers.",
    criteriaText:
      "Source code published under an open licence. Ranked by automatic zoom, cursor effects, captions, sharing, and AI-agent support.",
    include: (c) => truthy(c.features[ROW.openSource]),
    criteria: [ROW.autoZoom, ROW.cursor, ROW.captions, ROW.share, ROW.mcp],
    capturecat: {
      position: "first",
      note: "The Mac app, the API, and the website are one public repository under the AGPL-3.0.",
    },
    lastModified: FACTS_CHECKED,
  },
  {
    slug: "auto-zoom-screen-recorders",
    title: "Screen recorders with automatic zoom",
    description:
      "Every screen recorder we found that zooms in on your clicks automatically, without keyframing by hand, compared on price and platform.",
    intro:
      "Automatic zoom follows your clicks or cursor so viewers can read the UI without you keyframing every move. Only tools that do it automatically are listed; manual zoom tools are not.",
    criteriaText:
      "Verified automatic zoom. Ranked by cursor effects, captions, free tier, sharing, and AI-agent support.",
    include: (c) => c.features[ROW.autoZoom] === true,
    criteria: [ROW.cursor, ROW.captions, ROW.free, ROW.share, ROW.mcp],
    capturecat: {
      position: "first",
      note: "Zooms are placed from recorded clicks: tight clusters push in deeper, typing extends the hold. Free.",
    },
    lastModified: FACTS_CHECKED,
  },
  {
    slug: "screen-recorder-for-product-demos",
    title: "Best tools for product demo videos",
    description:
      "Screen recorders and demo tools for SaaS product demos, compared on automatic zoom, captions, editing, sharing, and price.",
    intro:
      "A product demo needs to look produced without taking a day to edit. These are the recorders, editors, and demo tools people use for launch videos, onboarding, and landing pages.",
    criteriaText:
      "Built for demos, or a recorder with a full editor. Ranked by automatic zoom, cursor effects, captions, sharing, and free tier.",
    include: (c) => ["demo", "editor", "interactive"].includes(c.category),
    criteria: [ROW.autoZoom, ROW.cursor, ROW.captions, ROW.share, ROW.free],
    capturecat: {
      position: "first",
      note: "Records once and applies the zooms, cursor smoothing, and captions automatically; exports 4K or shares a link with analytics.",
    },
    lastModified: FACTS_CHECKED,
  },
  {
    slug: "screen-recorders-for-ai-agents",
    title: "Screen recorders AI agents can use",
    description:
      "Screen recorders that Claude, ChatGPT, Cursor, and other AI agents can drive through an MCP server or official API, and which ones cannot.",
    intro:
      "If you work with an AI coding agent, it can record, edit, and export videos for you, but only if the recorder exposes its editor to the agent. Few do.",
    criteriaText:
      "An official MCP server or agent API, verified on the product's own site. Ranked by what the agent can do.",
    include: (c) => truthy(c.features[ROW.mcp]),
    criteria: [ROW.mcp, ROW.autoZoom, ROW.captions, ROW.free, ROW.share],
    capturecat: {
      position: "first",
      note: "A built-in MCP server with 28 tools: record, read clicks and transcripts, add zooms and blurs, render frames to check the edit, and export.",
    },
    lastModified: FACTS_CHECKED,
  },
  {
    slug: "screen-recorder-for-windows",
    title: "Best screen recorders for Windows",
    description:
      "Screen recorders for Windows 10 and 11, from the built-in tools to full editors, compared on features, captions, sharing, and price.",
    intro:
      "Windows has Xbox Game Bar and Snipping Tool built in. These are the options when you need editing, captions, sharing, or a polished result.",
    criteriaText:
      "Runs on Windows (natively or in a browser). Ranked by automatic zoom, cursor effects, captions, sharing, and free tier.",
    include: runsOnWindows,
    criteria: [ROW.autoZoom, ROW.cursor, ROW.captions, ROW.share, ROW.free],
    capturecat: {
      position: "last",
      note: "No native Windows app. The CaptureCat browser app records a display, window, or tab and runs the editor on WebGPU, but click-based auto zoom and cursor smoothing need a Mac recording. Listed last for that reason.",
      cells: {
        [ROW.autoZoom]: "Manual in browser",
        [ROW.cursor]: "Mac recordings only",
        [ROW.captions]: "In-browser (English)",
        [ROW.platform]: "Browser (no Windows app)",
      },
    },
    lastModified: FACTS_CHECKED,
  },
];

/* ------------------------------------------------------------------ */
/* Ranking                                                             */
/* ------------------------------------------------------------------ */

export interface BestEntry {
  name: string;
  /** null for CaptureCat itself. */
  competitor: Competitor | null;
  note: string;
  cells: FeatureCell[];
}

const OVERALL = [ROW.autoZoom, ROW.cursor, ROW.captions, ROW.mcp, ROW.share];

function score(cells: FeatureCell[], rows: number[]): number {
  return rows.filter((i) => (i === ROW.free ? isRealFreeTier(cells[i]) : truthy(cells[i])))
    .length;
}

export function bestEntries(list: BestList): BestEntry[] {
  const others = COMPETITORS.filter(list.include)
    .map((c, order) => ({ c, order }))
    .sort(
      (a, b) =>
        score(b.c.features, list.criteria) - score(a.c.features, list.criteria) ||
        score(b.c.features, OVERALL) - score(a.c.features, OVERALL) ||
        a.order - b.order
    )
    .map(({ c }) => ({
      name: c.name,
      competitor: c,
      note: `${c.summary} Pick it when ${c.pickThemWhen}`,
      cells: c.features,
    }));
  const self: BestEntry = {
    name: "CaptureCat",
    competitor: null,
    note: list.capturecat.note,
    cells: FEATURE_ROWS.map((r, i) =>
      list.capturecat.cells && i in list.capturecat.cells ? list.capturecat.cells[i]! : r.capturecat
    ),
  };
  return list.capturecat.position === "first" ? [self, ...others] : [...others, self];
}

/** Rows shown in a list's table: its criteria plus platform and price. */
export function bestTableRows(list: BestList): number[] {
  return [...list.criteria, ROW.platform, ROW.price].filter(
    (r, i, all) => all.indexOf(r) === i
  );
}

export function bestPath(list: BestList): string {
  return `/best/${list.slug}`;
}

export function findBestList(slug: string): BestList | undefined {
  return BEST_LISTS.find((l) => l.slug === slug);
}

export const DISCLOSURE =
  "We make CaptureCat, so it is in every list we write. Its position is stated, not earned by a score, and on lists where it is the weaker fit it goes last. Every other entry is ordered mechanically by the facts in the table, which were checked against each product's own site.";

/* ------------------------------------------------------------------ */
/* Markdown + JSON-LD                                                  */
/* ------------------------------------------------------------------ */

function entryLink(e: BestEntry): string {
  return e.competitor
    ? `[${e.name}](${SITE_URL}${comparePath(e.competitor)})`
    : `[CaptureCat](${SITE_URL})`;
}

function bestMarkdown(list: BestList): string {
  const entries = bestEntries(list);
  const rows = bestTableRows(list);
  const top = entries.slice(0, 3).map((e) => e.name);
  const table = [
    `| # | Recorder | ${rows.map((r) => FEATURE_ROWS[r].short).join(" | ")} |`,
    `| --- | --- | ${rows.map(() => "---").join(" | ")} |`,
    ...entries.map(
      (e, i) => `| ${i + 1} | ${entryLink(e)} | ${rows.map((r) => cellText(e.cells[r])).join(" | ")} |`
    ),
  ].join("\n");
  return `# ${list.title} (${FACTS_CHECKED.slice(0, 4)})

${list.intro}

**Short answer:** ${top.join(", ")}. ${entries.length} tools qualified; the full table is below.

## How we picked

${list.criteriaText} Facts checked ${FACTS_CHECKED}. ${DISCLOSURE}

## At a glance

${table}

"check their site" means we could not verify it either way.

${entries
  .map((e, i) => `## ${i + 1}. ${e.name}\n\n${e.note}${e.competitor ? `\n\n[CaptureCat vs ${e.name}](${SITE_URL}${comparePath(e.competitor)})` : ""}`)
  .join("\n\n")}

---

[All comparisons](${SITE_URL}/compare) · [Download CaptureCat for Mac](${SITE_URL}/download)
`;
}

export function bestJsonLd(list: BestList): object {
  const url = `${SITE_URL}${bestPath(list)}`;
  const entries = bestEntries(list);
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "Article",
        "@id": `${url}#article`,
        headline: list.title,
        description: list.description,
        url,
        dateModified: list.lastModified,
        author: { "@type": "Organization", name: "CaptureCat", url: SITE_URL },
        publisher: { "@type": "Organization", name: "CaptureCat", url: SITE_URL },
        mainEntity: { "@id": `${url}#list` },
      },
      {
        "@type": "ItemList",
        "@id": `${url}#list`,
        name: list.title,
        itemListOrder: "https://schema.org/ItemListOrderAscending",
        numberOfItems: entries.length,
        itemListElement: entries.map((e, i) => ({
          "@type": "ListItem",
          position: i + 1,
          item: e.competitor
            ? {
                "@type": "SoftwareApplication",
                name: e.name,
                url: e.competitor.website,
                applicationCategory: "MultimediaApplication",
              }
            : { "@id": `${SITE_URL}/#app` },
        })),
      },
      {
        "@type": "BreadcrumbList",
        itemListElement: [
          { "@type": "ListItem", position: 1, name: "Home", item: SITE_URL },
          { "@type": "ListItem", position: 2, name: "Best-of lists", item: `${SITE_URL}/best` },
          { "@type": "ListItem", position: 3, name: list.title, item: url },
        ],
      },
      captureCatJsonLd(),
    ],
  };
}

export const BEST_HUB_DESCRIPTION =
  "Best-of screen recorder lists from sourced facts: Mac, free, open source, auto zoom, Loom and Screen Studio alternatives, Windows, and AI agents.";

const bestHubMarkdown = `# Best screen recorder lists (${FACTS_CHECKED.slice(0, 4)})

Every list is generated from the same sourced comparison data, checked
${FACTS_CHECKED}. ${DISCLOSURE}

${BEST_LISTS.map((l) => `- [${l.title}](${SITE_URL}${bestPath(l)}): ${l.description}`).join("\n")}

[All comparisons](${SITE_URL}/compare) · [Download CaptureCat for Mac](${SITE_URL}/download)
`;

export function bestHubJsonLd(): object {
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "CollectionPage",
        "@id": `${SITE_URL}/best`,
        name: "Best screen recorder lists",
        url: `${SITE_URL}/best`,
        about: { "@id": `${SITE_URL}/#app` },
        mainEntity: { "@id": `${SITE_URL}/best#list` },
      },
      {
        "@type": "ItemList",
        "@id": `${SITE_URL}/best#list`,
        itemListElement: BEST_LISTS.map((l, i) => ({
          "@type": "ListItem",
          position: i + 1,
          name: l.title,
          url: `${SITE_URL}${bestPath(l)}`,
        })),
      },
      captureCatJsonLd(),
    ],
  };
}

export const BEST_SITE_PAGES: SitePage[] = [
  {
    path: "/best",
    title: "Best screen recorder lists",
    seoTitle: `Best screen recorders (${FACTS_CHECKED.slice(0, 4)}): every list | CaptureCat`,
    description: BEST_HUB_DESCRIPTION,
    lastModified: FACTS_CHECKED,
    markdown: bestHubMarkdown,
  },
  ...BEST_LISTS.map((list) => ({
  path: bestPath(list),
  title: `${list.title} (${FACTS_CHECKED.slice(0, 4)})`,
  ogType: "article" as const,
  description: list.description,
  lastModified: list.lastModified,
  markdown: bestMarkdown(list),
})),
];
