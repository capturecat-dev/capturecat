import type { SitePage } from "../site-content";
import { captureCatJsonLd } from "../pseo-content";
import { SITE_URL } from "../site-url";
import type { DocBlock, DocPage, DocSection } from "./types";

import { GETTING_STARTED } from "./sections/getting-started";
import { RECORDING } from "./sections/recording";
import { EDITING } from "./sections/editing";
import { EXPORT_AND_SHARING } from "./sections/export-and-sharing";
import { CUSTOM_STORAGE } from "./sections/custom-storage";
import { TEAMS } from "./sections/teams";
import { LIBRARY } from "./sections/library";
import { WEB_APP } from "./sections/web-app";
import { AI_AGENTS } from "./sections/ai-agents";
import { ACCOUNT } from "./sections/account";
import { SELF_HOSTING } from "./sections/self-hosting";

export type { DocBlock, DocPage, DocSection } from "./types";

/**
 * /docs — the product documentation, one typed record per page (types.ts).
 *
 * Sidebar order is this array's order, then each section's page order. Every
 * page is appended to SITE_PAGES (site-content.ts), so it gets its head tags,
 * a sitemap entry, an llms.txt line and a Markdown twin at /docs/….md from
 * this one record. Keep claims shippable: each section was checked against
 * apps/macos, apps/web and apps/api on its `lastModified` date.
 */
export const DOC_SECTIONS: DocSection[] = [
  GETTING_STARTED,
  RECORDING,
  EDITING,
  EXPORT_AND_SHARING,
  CUSTOM_STORAGE,
  TEAMS,
  LIBRARY,
  WEB_APP,
  AI_AGENTS,
  ACCOUNT,
  SELF_HOSTING,
].filter((s) => s.pages.length > 0);

export interface LocatedDoc {
  page: DocPage;
  section: DocSection;
}

export const ALL_DOCS: LocatedDoc[] = DOC_SECTIONS.flatMap((section) =>
  section.pages.map((page) => ({ page, section }))
);

const BY_SLUG = new Map(ALL_DOCS.map((d) => [d.page.slug, d]));

export function findDoc(slug: string): LocatedDoc | undefined {
  return BY_SLUG.get(slug.replace(/^\/+|\/+$/g, ""));
}

export function docPath(page: DocPage | string): string {
  return `/docs/${typeof page === "string" ? page : page.slug}`;
}

export function docNavTitle(page: DocPage): string {
  return page.navTitle ?? page.title;
}

/** Reading order across the whole sidebar. */
export function prevNext(slug: string): { prev?: DocPage; next?: DocPage } {
  const i = ALL_DOCS.findIndex((d) => d.page.slug === slug);
  return { prev: ALL_DOCS[i - 1]?.page, next: ALL_DOCS[i + 1]?.page };
}

export function relatedDocs(page: DocPage): DocPage[] {
  return (page.related ?? []).flatMap((s) => {
    const d = findDoc(s);
    return d ? [d.page] : [];
  });
}

/** Stable anchor for a heading. */
export function headingId(block: Extract<DocBlock, { type: "h2" | "h3" }>): string {
  return (
    block.id ??
    block.text
      .toLowerCase()
      .replace(/[`*[\]()]/g, "")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "")
  );
}

/** Strip the inline-Markdown subset to plain text (JSON-LD, meta). */
export function plainText(text: string): string {
  return text
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/`([^`]+)`/g, "$1");
}

const PLATFORM_LABEL = { mac: "Mac app", web: "Web app" } as const;
const PLAN_LABEL = { pro: "Pro", business: "Business" } as const;

export function availabilityLine(page: DocPage): string | null {
  const parts: string[] = [];
  if (page.platforms?.length) parts.push(page.platforms.map((p) => PLATFORM_LABEL[p]).join(" and "));
  parts.push(page.plan ? `${PLAN_LABEL[page.plan]} plan` : "Free");
  return page.platforms?.length || page.plan ? parts.join(" · ") : null;
}

// ---------------------------------------------------------------------------
// Markdown twin
// ---------------------------------------------------------------------------

function absolutize(text: string): string {
  return text.replace(/\]\((\/[^)]*)\)/g, (_, p: string) => `](${SITE_URL}${p})`);
}

function blockMarkdown(block: DocBlock): string {
  switch (block.type) {
    case "p":
      return absolutize(block.text);
    case "h2":
      return `## ${block.text}`;
    case "h3":
      return `### ${block.text}`;
    case "list":
      return block.items.map((item, i) => `${block.ordered ? `${i + 1}.` : "-"} ${absolutize(item)}`).join("\n");
    case "steps":
      return block.steps.map((s, i) => `${i + 1}. **${s.title}.** ${absolutize(s.text)}`).join("\n");
    case "code":
      return `${block.caption ? `${absolutize(block.caption)}\n\n` : ""}\`\`\`${block.lang ?? ""}\n${block.code}\n\`\`\``;
    case "callout":
      return `> **${block.title ?? { note: "Note", tip: "Tip", warning: "Warning", pro: "Pro" }[block.tone]}:** ${absolutize(block.text)}`;
    case "table":
      return [
        `| ${block.head.join(" | ")} |`,
        `| ${block.head.map(() => "---").join(" | ")} |`,
        ...block.rows.map((r) => `| ${r.map(absolutize).join(" | ")} |`),
      ].join("\n");
    case "shortcuts":
      return ["| Shortcut | Action |", "| --- | --- |", ...block.rows.map(([k, a]) => `| ${k} | ${a} |`)].join("\n");
  }
}

export function docMarkdown({ page, section }: LocatedDoc): string {
  const availability = availabilityLine(page);
  const parts = [
    `# ${page.title}`,
    `*${section.title} · CaptureCat docs*${availability ? ` · ${availability}` : ""}`,
    absolutize(page.summary),
    ...page.blocks.map(blockMarkdown),
  ];
  if (page.faqs?.length) {
    parts.push("## FAQ", ...page.faqs.map((f) => `### ${f.question}\n\n${absolutize(f.answer)}`));
  }
  const related = relatedDocs(page);
  if (related.length) {
    parts.push("## Related", related.map((r) => `- [${r.title}](${SITE_URL}${docPath(r)})`).join("\n"));
  }
  return `${parts.join("\n\n")}\n`;
}

function hubMarkdown(): string {
  return `# CaptureCat documentation

How to record, edit, export and share with CaptureCat on the Mac and in the
browser, plus Pro features, AI agents, and self-hosting the open-source
backend.

${DOC_SECTIONS.map(
  (s) =>
    `## ${s.title}\n\n${s.description}\n\n${s.pages
      .map((p) => `- [${p.title}](${SITE_URL}${docPath(p)}): ${p.description}`)
      .join("\n")}`
).join("\n\n")}
`;
}

// ---------------------------------------------------------------------------
// JSON-LD
// ---------------------------------------------------------------------------

export function docJsonLd({ page, section }: LocatedDoc): object {
  const url = `${SITE_URL}${docPath(page)}`;
  const steps = page.blocks.find((b): b is Extract<DocBlock, { type: "steps" }> => b.type === "steps");
  const graph: object[] = [
    {
      "@type": "TechArticle",
      "@id": `${url}#article`,
      headline: page.title,
      description: page.description,
      url,
      dateModified: page.lastModified,
      inLanguage: "en",
      isPartOf: { "@id": `${SITE_URL}/docs#docs` },
      about: { "@id": `${SITE_URL}/#app` },
      breadcrumb: { "@id": `${url}#breadcrumb` },
      publisher: { "@type": "Organization", name: "CaptureCat", url: SITE_URL },
    },
    {
      "@type": "BreadcrumbList",
      "@id": `${url}#breadcrumb`,
      itemListElement: [
        { "@type": "ListItem", position: 1, name: "Home", item: SITE_URL },
        { "@type": "ListItem", position: 2, name: "Docs", item: `${SITE_URL}/docs` },
        { "@type": "ListItem", position: 3, name: section.title, item: `${SITE_URL}${docPath(section.pages[0])}` },
        { "@type": "ListItem", position: 4, name: docNavTitle(page), item: url },
      ],
    },
  ];
  if (steps) {
    graph.push({
      "@type": "HowTo",
      "@id": `${url}#howto`,
      name: page.title,
      description: plainText(page.summary),
      tool: { "@id": `${SITE_URL}/#app` },
      step: steps.steps.map((s, i) => ({
        "@type": "HowToStep",
        position: i + 1,
        name: plainText(s.title),
        text: plainText(s.text),
      })),
    });
  }
  if (page.faqs?.length) {
    graph.push({
      "@type": "FAQPage",
      "@id": `${url}#faq`,
      mainEntity: page.faqs.map((f) => ({
        "@type": "Question",
        name: f.question,
        acceptedAnswer: { "@type": "Answer", text: plainText(f.answer) },
      })),
    });
  }
  graph.push(captureCatJsonLd());
  return { "@context": "https://schema.org", "@graph": graph };
}

export function docsHubJsonLd(): object {
  const url = `${SITE_URL}/docs`;
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "CollectionPage",
        "@id": `${url}#docs`,
        name: "CaptureCat documentation",
        description: DOCS_HUB_DESCRIPTION,
        url,
        about: { "@id": `${SITE_URL}/#app` },
        hasPart: ALL_DOCS.map((d) => ({ "@id": `${SITE_URL}${docPath(d.page)}#article` })),
      },
      captureCatJsonLd(),
    ],
  };
}

// ---------------------------------------------------------------------------
// Registry entries (consumed by site-content.ts)
// ---------------------------------------------------------------------------

export const DOCS_HUB_DESCRIPTION =
  "CaptureCat docs: record, auto zoom, captions, export and share links on Mac and web, plus custom S3 storage, teams, AI agents (MCP) and self-hosting.";

const HUB_LAST_MODIFIED = ALL_DOCS.reduce((max, d) => (d.page.lastModified > max ? d.page.lastModified : max), "2026-10-07");

export const DOC_SITE_PAGES: SitePage[] = [
  {
    path: "/docs",
    title: "Documentation",
    seoTitle: "CaptureCat Docs: Mac screen recorder guide and reference",
    description: DOCS_HUB_DESCRIPTION,
    lastModified: HUB_LAST_MODIFIED,
    markdown: hubMarkdown(),
  },
  ...ALL_DOCS.map((d) => ({
    path: docPath(d.page),
    title: d.page.title,
    // "Title | CaptureCat Docs" while it fits a search result; longer titles
    // fall back to pageHead's own " | CaptureCat" rule.
    seoTitle:
      d.page.seoTitle ??
      (`${d.page.title} | CaptureCat Docs`.length <= 62 ? `${d.page.title} | CaptureCat Docs` : undefined),
    ogType: "article" as const,
    description: d.page.description,
    lastModified: d.page.lastModified,
    markdown: docMarkdown(d),
  })),
];
