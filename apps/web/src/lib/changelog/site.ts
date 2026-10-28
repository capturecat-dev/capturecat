/**
 * The public changelog on capturecat.so: its paths, its <head>, and the API
 * reads behind it (GET /api/changelog, apps/api/src/routes/changelog.ts).
 *
 * Not in the SITE_PAGES registry on purpose: that registry is static content
 * (its Markdown is a string in the bundle), while the changelog comes from D1
 * and changes without a deploy. Every discovery surface the registry feeds is
 * wired here instead — sitemap.xml, llms.txt, llms-full.txt, the .md twins and
 * the Link/Vary headers in src/server.ts all ask `isChangelogPath` /
 * `fetchAllChangelog`.
 *
 * Reads fail soft: `null` means the API could not be reached, which the pages
 * show as "couldn't load" (not as an empty changelog), and the feeds and the
 * sitemap simply leave the entries out until it is back.
 */
import { API_URL } from "@/lib/api-url";
import { OG_IMAGE, SITE_URL, canonicalUrl } from "@/lib/site-content";

import { SLUG_PATTERN, type ChangelogEntry, type ChangelogPage } from "./model";

export const CHANGELOG_PATH = "/changelog";
export const CHANGELOG_FEED_PATH = "/changelog.xml";
export const CHANGELOG_TITLE = "Changelog";
export const CHANGELOG_SEO_TITLE = "Changelog: what's new in CaptureCat";
export const CHANGELOG_DESCRIPTION =
  "Every CaptureCat update: new features, improvements, fixes and security notes for the Mac app, the web app, the API and agents.";

/** Entries per page on /changelog (the API allows up to 50). */
export const CHANGELOG_PAGE_SIZE = 20;

export const changelogEntryPath = (slug: string) => `${CHANGELOG_PATH}/${slug}`;

/** "/changelog" or "/changelog/<slug>" — the pages that have a Markdown twin. */
export function isChangelogPath(path: string): boolean {
  if (path === CHANGELOG_PATH) return true;
  const slug = path.startsWith(`${CHANGELOG_PATH}/`) ? path.slice(CHANGELOG_PATH.length + 1) : "";
  return slug.length > 0 && slug.length <= 80 && SLUG_PATTERN.test(slug);
}

/** The Markdown twin's public URL for a changelog page path. */
export const changelogMarkdownHref = (path: string) => `${path}.md`;

// ── API reads ───────────────────────────────────────────────────────────────

const TIMEOUT_MS = 4000;

export async function fetchChangelog(
  opts: { limit?: number; cursor?: string | null } = {},
): Promise<ChangelogPage | null> {
  const qs = new URLSearchParams({ limit: String(opts.limit ?? CHANGELOG_PAGE_SIZE) });
  if (opts.cursor) qs.set("cursor", opts.cursor);
  try {
    const res = await fetch(`${API_URL}/api/changelog?${qs}`, { signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (res.status === 400 && opts.cursor) return { entries: [], nextCursor: null }; // a stale/garbled cursor
    if (!res.ok) return null;
    const body = (await res.json()) as Partial<ChangelogPage>;
    return { entries: Array.isArray(body.entries) ? body.entries : [], nextCursor: body.nextCursor ?? null };
  } catch {
    return null;
  }
}

/** One entry; `null` = no such published entry; "error" = the API is unreachable. */
export async function fetchChangelogEntry(slug: string): Promise<ChangelogEntry | null | "error"> {
  if (!SLUG_PATTERN.test(slug) || slug.length > 80) return null;
  try {
    const res = await fetch(`${API_URL}/api/changelog/${encodeURIComponent(slug)}`, {
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (res.status === 404) return null;
    if (!res.ok) return "error";
    return ((await res.json()) as { entry: ChangelogEntry }).entry ?? null;
  } catch {
    return "error";
  }
}

/** Every published entry (newest first, capped), for the feeds and the sitemap. */
export async function fetchAllChangelog(max = 500): Promise<ChangelogEntry[] | null> {
  const all: ChangelogEntry[] = [];
  let cursor: string | null = null;
  do {
    const page = await fetchChangelog({ limit: 50, cursor });
    if (!page) return all.length ? all : null;
    all.push(...page.entries);
    cursor = page.nextCursor;
  } while (cursor && all.length < max);
  return all.slice(0, max);
}

// ── <head> ──────────────────────────────────────────────────────────────────

type HeadMeta = Record<string, string>;
type HeadLink = { rel: string; href: string; type?: string; title?: string };

/** The same head shape pageHead() gives registry pages, plus the RSS feed. */
export function changelogHead(opts: {
  path: string;
  title: string;
  description: string;
  ogType?: "website" | "article";
  /** Paged views (?cursor=) are for people, not the index. */
  noindex?: boolean;
  publishedAt?: string;
  modifiedAt?: string;
}): { meta: HeadMeta[]; links: HeadLink[] } {
  const url = canonicalUrl(opts.path);
  const meta: HeadMeta[] = [
    { title: opts.title },
    { name: "description", content: opts.description },
    { property: "og:site_name", content: "CaptureCat" },
    { property: "og:type", content: opts.ogType ?? "website" },
    { property: "og:title", content: opts.title },
    { property: "og:description", content: opts.description },
    { property: "og:url", content: url },
    { property: "og:image", content: OG_IMAGE.url },
    { property: "og:image:width", content: String(OG_IMAGE.width) },
    { property: "og:image:height", content: String(OG_IMAGE.height) },
    { property: "og:image:alt", content: OG_IMAGE.alt },
    { name: "twitter:card", content: "summary_large_image" },
    { name: "twitter:title", content: opts.title },
    { name: "twitter:description", content: opts.description },
    { name: "twitter:image", content: OG_IMAGE.url },
  ];
  if (opts.publishedAt) meta.push({ property: "article:published_time", content: opts.publishedAt });
  if (opts.modifiedAt) meta.push({ property: "article:modified_time", content: opts.modifiedAt });
  if (opts.noindex) meta.push({ name: "robots", content: "noindex, follow" });
  return {
    meta,
    links: [
      { rel: "canonical", href: url },
      { rel: "alternate", type: "text/markdown", href: changelogMarkdownHref(opts.path) },
      { rel: "alternate", type: "application/rss+xml", title: "CaptureCat changelog", href: `${SITE_URL}${CHANGELOG_FEED_PATH}` },
    ],
  };
}
