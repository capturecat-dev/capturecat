/**
 * The changelog's machine-readable twins: the Markdown pages
 * (/changelog.md, /changelog/<slug>.md, and its part of llms-full.txt) and the
 * RSS 2.0 feed (/changelog.xml). Pure functions of the entries, so they are
 * tested without a server (feeds.test.ts).
 *
 * The Markdown twin passes each body through as written (it is already
 * Markdown, by the owner), with its headings pushed below the entry's own.
 * The feed's HTML comes from the same escaped renderer as the page
 * (markdown.tsx `markdownToHtml`), then XML-escaped.
 */
import { escapeHtml, markdownToHtml } from "./markdown";
import { CATEGORY_META, PLATFORM_LABELS, formatChangelogDate, groupByMonth, versionLabel, type ChangelogEntry } from "./model";

export interface FeedSite {
  /** "https://capturecat.so" */
  siteUrl: string;
  title: string;
  description: string;
}

const entryUrl = (site: FeedSite, slug: string) => `${site.siteUrl}/changelog/${slug}`;

/**
 * Puts a body's ATX headings under an entry heading of level `under`, the way
 * the page renders them (markdown.tsx): `#` and `##` become the level just
 * below the entry, `###` and deeper one more (max h6). Code fences are left alone.
 */
export function demoteHeadings(markdown: string, under: number): string {
  let fence: string | null = null;
  return markdown
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((line) => {
      const f = /^ {0,3}(`{3,}|~{3,})/.exec(line);
      if (f) {
        if (!fence) fence = f[1][0];
        else if (f[1][0] === fence) fence = null;
        return line;
      }
      if (fence) return line;
      return line.replace(/^( {0,3})(#{1,6})(?=[ \t]|$)/, (_m, sp: string, hashes: string) =>
        sp + "#".repeat(Math.min(6, under + (hashes.length <= 2 ? 1 : 2))),
      );
    })
    .join("\n");
}

function metaLine(entry: ChangelogEntry): string {
  const parts = [formatChangelogDate(entry.publishedAt)];
  if (entry.version) parts.push(versionLabel(entry.version));
  parts.push(CATEGORY_META[entry.category]?.label ?? entry.category);
  if (entry.platforms.length) parts.push(entry.platforms.map((p) => PLATFORM_LABELS[p] ?? p).join(", "));
  return parts.join(" · ");
}

function entrySection(entry: ChangelogEntry, site: FeedSite, level: number): string {
  const hashes = "#".repeat(level);
  const body = entry.body.trim() ? `\n\n${demoteHeadings(entry.body.trim(), level)}` : "";
  return `${hashes} ${entry.title}\n\n_${metaLine(entry)}_ · [Permalink](${entryUrl(site, entry.slug)})\n\n${entry.summary}${body}\n`;
}

/** /changelog.md — every entry, grouped by month like the page. */
export function changelogMarkdown(entries: ChangelogEntry[], site: FeedSite): string {
  const head = `# ${site.title}\n\n> ${site.description}\n\nNewest first. RSS: ${site.siteUrl}/changelog.xml · Web: ${site.siteUrl}/changelog\n`;
  if (entries.length === 0) return `${head}\nNo entries yet.\n`;
  const months = groupByMonth(entries).map(
    (g) => `## ${g.label}\n\n${g.entries.map((e) => entrySection(e, site, 3)).join("\n")}`,
  );
  return `${head}\n${months.join("\n")}`;
}

/** /changelog/<slug>.md — one entry. */
export function changelogEntryMarkdown(entry: ChangelogEntry, site: FeedSite): string {
  return `${entrySection(entry, site, 1)}\n[All updates](${site.siteUrl}/changelog)\n`;
}

// ── RSS 2.0 ────────────────────────────────────────────────────────────────

/** XML 1.0 text: escaped, and with the control characters XML forbids removed. */
export function escapeXml(text: string): string {
  return text
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

const rfc822 = (iso: string) => new Date(iso).toUTCString();

export function changelogRss(entries: ChangelogEntry[], site: FeedSite): string {
  const latest = entries[0];
  const items = entries.map((e) => {
    const url = entryUrl(site, e.slug);
    const categories = [CATEGORY_META[e.category]?.label ?? e.category, ...e.platforms.map((p) => PLATFORM_LABELS[p] ?? p)];
    const title = e.version ? `${e.title} (${versionLabel(e.version)})` : e.title;
    const html = `<p>${escapeHtml(e.summary)}</p>\n${markdownToHtml(e.body, 2)}`;
    return [
      "    <item>",
      `      <title>${escapeXml(title)}</title>`,
      `      <link>${escapeXml(url)}</link>`,
      `      <guid isPermaLink="true">${escapeXml(url)}</guid>`,
      `      <pubDate>${rfc822(e.publishedAt)}</pubDate>`,
      ...categories.map((c) => `      <category>${escapeXml(c)}</category>`),
      `      <description>${escapeXml(e.summary)}</description>`,
      `      <content:encoded>${escapeXml(html)}</content:encoded>`,
      "    </item>",
    ].join("\n");
  });
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:content="http://purl.org/rss/1.0/modules/content/">',
    "  <channel>",
    `    <title>${escapeXml(site.title)}</title>`,
    `    <link>${escapeXml(`${site.siteUrl}/changelog`)}</link>`,
    `    <description>${escapeXml(site.description)}</description>`,
    "    <language>en-gb</language>",
    `    <atom:link href="${escapeXml(`${site.siteUrl}/changelog.xml`)}" rel="self" type="application/rss+xml"/>`,
    ...(latest ? [`    <lastBuildDate>${rfc822(latest.updatedAt > latest.publishedAt ? latest.updatedAt : latest.publishedAt)}</lastBuildDate>`] : []),
    ...items,
    "  </channel>",
    "</rss>",
    "",
  ].join("\n");
}
