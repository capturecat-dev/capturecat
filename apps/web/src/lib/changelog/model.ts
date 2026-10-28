/**
 * The changelog's model, shared by the public pages (capturecat.so/changelog)
 * and the admin console's editor (apps/admin imports this file by relative
 * path, like apps/api's tests import web modules). Pure TypeScript: no React,
 * no `@/` imports, so it resolves the same from either app.
 *
 * The category and platform values mirror CHANGELOG_CATEGORIES /
 * CHANGELOG_PLATFORMS in apps/api/src/routes/changelog.ts, which validates
 * them; the API's test suite imports this file and fails if they drift.
 */

export const CHANGELOG_CATEGORIES = ["new", "improved", "fixed", "security"] as const;
export const CHANGELOG_PLATFORMS = ["mac", "web", "api", "agents"] as const;
export type ChangelogCategory = (typeof CHANGELOG_CATEGORIES)[number];
export type ChangelogPlatform = (typeof CHANGELOG_PLATFORMS)[number];

/** Field caps, as the API enforces them. */
export const CHANGELOG_LIMITS = { slug: 80, title: 140, summary: 280, body: 50_000, version: 32 } as const;

/** One published entry as GET /api/changelog returns it. */
export interface ChangelogEntry {
  slug: string;
  title: string;
  summary: string;
  /** Markdown, rendered by ./markdown.tsx (escaped; http(s) links only). */
  body: string;
  category: ChangelogCategory;
  platforms: ChangelogPlatform[];
  version: string | null;
  /** ISO 8601. */
  publishedAt: string;
  updatedAt: string;
}

export interface ChangelogPage {
  entries: ChangelogEntry[];
  nextCursor: string | null;
}

/**
 * Badge looks, in the site's glass language: a tinted hairline border over a
 * faint wash, the same four tints as the docs callouts.
 */
export const CATEGORY_META: Record<ChangelogCategory, { label: string; badge: string }> = {
  new: { label: "New", badge: "border-cyan-300/25 bg-cyan-300/[0.08] text-cyan-200" },
  improved: { label: "Improved", badge: "border-violet-300/25 bg-violet-300/[0.09] text-violet-200" },
  fixed: { label: "Fixed", badge: "border-emerald-300/25 bg-emerald-300/[0.08] text-emerald-200" },
  security: { label: "Security", badge: "border-amber-300/30 bg-amber-300/[0.09] text-amber-200" },
};

export const PLATFORM_LABELS: Record<ChangelogPlatform, string> = {
  mac: "Mac",
  web: "Web",
  api: "API",
  agents: "Agents",
};

/** "1.3.1" → "v1.3.1"; anything not starting with a digit is shown as written. */
export function versionLabel(version: string): string {
  return /^\d/.test(version) ? `v${version}` : version;
}

export function isCategory(value: unknown): value is ChangelogCategory {
  return (CHANGELOG_CATEGORIES as readonly unknown[]).includes(value);
}

/** "Agents keep their tokens: 1.3.1!" → "agents-keep-their-tokens-1-3-1". */
export function slugify(title: string): string {
  return title
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, CHANGELOG_LIMITS.slug)
    .replace(/-+$/g, "");
}

export const SLUG_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

/**
 * "28 October 2026". UTC on purpose: the page is rendered on the server
 * (UTC) and hydrated in the reader's zone, and the two must print the same
 * day or React re-renders the text.
 */
export function formatChangelogDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
}

/** "October 2026" (UTC, like the dates). */
export function monthLabel(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString("en-GB", { month: "long", year: "numeric", timeZone: "UTC" });
}

/** Entries (already newest first) in runs of one calendar month. */
export function groupByMonth<T extends { publishedAt: string }>(entries: T[]): Array<{ key: string; label: string; entries: T[] }> {
  const groups: Array<{ key: string; label: string; entries: T[] }> = [];
  for (const entry of entries) {
    const key = entry.publishedAt.slice(0, 7);
    const last = groups[groups.length - 1];
    if (last && last.key === key) last.entries.push(entry);
    else groups.push({ key, label: monthLabel(entry.publishedAt), entries: [entry] });
  }
  return groups;
}
