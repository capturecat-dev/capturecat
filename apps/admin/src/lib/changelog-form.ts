/**
 * The changelog editor's model — what the form holds, how it becomes the
 * body of POST/PUT /api/admin/changelog, and the status line the list shows.
 * Kept free of React (changelog-form.test.ts).
 *
 * The categories, platforms, slug rule and date format come from the public
 * site's own model (apps/web/src/lib/changelog/model.ts, imported by relative
 * path — the same way apps/api's tests import web modules), so the editor,
 * the preview and capturecat.so/changelog cannot disagree about them. The
 * API's test suite pins that model to the API's validation lists.
 */
import {
  CHANGELOG_LIMITS,
  CHANGELOG_PLATFORMS,
  SLUG_PATTERN,
  formatChangelogDate,
  slugify,
  type ChangelogCategory,
  type ChangelogPlatform,
} from "../../../web/src/lib/changelog/model";
import type { ChangelogEntryLike } from "../../../web/src/lib/changelog/entry-view";

export {
  CATEGORY_META,
  CHANGELOG_CATEGORIES,
  CHANGELOG_LIMITS,
  CHANGELOG_PLATFORMS,
  PLATFORM_LABELS,
  formatChangelogDate,
  slugify,
  versionLabel,
  type ChangelogCategory,
  type ChangelogPlatform,
} from "../../../web/src/lib/changelog/model";

/** GET /api/admin/changelog's entry (apps/api/src/routes/changelog.ts `adminEntry`). */
export interface AdminChangelogEntry {
  id: string;
  slug: string;
  title: string;
  summary: string;
  body: string;
  category: ChangelogCategory;
  platforms: ChangelogPlatform[];
  version: string | null;
  /** null = draft. */
  publishedAt: string | null;
  status: "draft" | "scheduled" | "published";
  createdAt: string;
  updatedAt: string;
  /** The author's email (or id, if the account is gone). */
  createdBy: string | null;
}

export interface ChangelogForm {
  title: string;
  slug: string;
  /** Once the slug is typed by hand it stops following the title. */
  slugEdited: boolean;
  summary: string;
  body: string;
  category: ChangelogCategory;
  platforms: ChangelogPlatform[];
  version: string;
  /** YYYY-MM-DD (UTC) or "" = the moment it is published. */
  date: string;
}

export interface ChangelogInput {
  slug: string;
  title: string;
  summary: string;
  body: string;
  category: ChangelogCategory;
  platforms: ChangelogPlatform[];
  version: string | null;
}

export function emptyChangelogForm(): ChangelogForm {
  return { title: "", slug: "", slugEdited: false, summary: "", body: "", category: "new", platforms: [], version: "", date: "" };
}

/** The UTC calendar day of an instant, as a date input shows it. */
export const isoDay = (iso: string | null) => (iso ? iso.slice(0, 10) : "");

export function formFromEntry(entry: AdminChangelogEntry): ChangelogForm {
  return {
    title: entry.title,
    slug: entry.slug,
    // A saved slug is a URL: it never silently follows a retyped title.
    slugEdited: true,
    summary: entry.summary,
    body: entry.body,
    category: entry.category,
    platforms: [...entry.platforms],
    version: entry.version ?? "",
    date: isoDay(entry.publishedAt),
  };
}

/** Typing the title re-suggests the slug until the slug is edited by hand. */
export function withTitle(form: ChangelogForm, title: string): ChangelogForm {
  return { ...form, title, slug: form.slugEdited ? form.slug : slugify(title) };
}

/** What the slug input accepts as it is typed (the API lower-cases and checks the rest). */
export function cleanSlugInput(value: string): string {
  return value
    .toLowerCase()
    .replace(/[\s_]+/g, "-")
    .replace(/[^a-z0-9-]/g, "")
    .slice(0, CHANGELOG_LIMITS.slug);
}

export function togglePlatform(list: ChangelogPlatform[], platform: ChangelogPlatform): ChangelogPlatform[] {
  const on = list.includes(platform);
  return CHANGELOG_PLATFORMS.filter((p) => (p === platform ? !on : list.includes(p)));
}

export function inputFromForm(form: ChangelogForm): ChangelogInput {
  return {
    slug: form.slug.trim(),
    title: form.title.trim(),
    summary: form.summary.replace(/\s+/g, " ").trim(),
    body: form.body,
    category: form.category,
    platforms: CHANGELOG_PLATFORMS.filter((p) => form.platforms.includes(p)),
    version: form.version.trim() || null,
  };
}

/** The first thing stopping a save, in the API's words, or null. */
export function formProblem(form: ChangelogForm): string | null {
  const input = inputFromForm(form);
  if (!input.title) return "Give it a title.";
  if (input.title.length > CHANGELOG_LIMITS.title) return `The title is too long (max ${CHANGELOG_LIMITS.title}).`;
  if (!input.slug) return "Give it a slug.";
  if (!SLUG_PATTERN.test(input.slug)) return "The slug is lowercase letters, digits and single hyphens, with no hyphen at either end.";
  if (!input.summary) return "Write the one-line summary.";
  if (input.summary.length > CHANGELOG_LIMITS.summary) return `The summary is too long (max ${CHANGELOG_LIMITS.summary}).`;
  if (input.body.length > CHANGELOG_LIMITS.body) return `The body is too long (max ${CHANGELOG_LIMITS.body.toLocaleString("en-GB")} characters).`;
  if (input.version && input.version.length > CHANGELOG_LIMITS.version) return `The version is too long (max ${CHANGELOG_LIMITS.version}).`;
  return null;
}

/** Content differs from what was saved (the date is compared separately). */
export function contentChanged(form: ChangelogForm, saved: AdminChangelogEntry | null): boolean {
  if (!saved) return true;
  const a = inputFromForm(form);
  return (
    a.slug !== saved.slug ||
    a.title !== saved.title ||
    a.summary !== saved.summary ||
    a.body !== saved.body ||
    a.category !== saved.category ||
    a.version !== saved.version ||
    a.platforms.join(",") !== saved.platforms.join(",")
  );
}

/** Anything at all to lose by closing the editor. */
export function isDirty(form: ChangelogForm, saved: AdminChangelogEntry | null): boolean {
  if (!saved) {
    const blank = emptyChangelogForm();
    return (
      form.title.trim() !== "" ||
      form.summary.trim() !== "" ||
      form.body.trim() !== "" ||
      form.version.trim() !== "" ||
      form.platforms.length > 0 ||
      form.category !== blank.category ||
      form.date !== ""
    );
  }
  return contentChanged(form, saved) || (saved.publishedAt !== null && form.date !== isoDay(saved.publishedAt));
}

/** The date to publish with: "" = now (or keep the date it has). */
export const publishDate = (form: ChangelogForm): string | null => (form.date ? form.date : null);

/** A YYYY-MM-DD later than today (UTC) schedules rather than publishes. */
export function isFutureDay(day: string, now = new Date()): boolean {
  return !!day && day > now.toISOString().slice(0, 10);
}

/** The status column / editor badge: "Draft", "Published 28 October 2026", "Scheduled for …". */
export function statusLine(entry: Pick<AdminChangelogEntry, "status" | "publishedAt">): string {
  if (entry.status === "draft" || !entry.publishedAt) return "Draft";
  const day = formatChangelogDate(entry.publishedAt);
  return entry.status === "scheduled" ? `Scheduled for ${day}` : `Published ${day}`;
}

/**
 * What the preview renders: the form as the public page would show it. A
 * draft with no date shows today's (that is what publishing now would print).
 */
export function previewEntry(form: ChangelogForm, saved: AdminChangelogEntry | null, now = new Date()): ChangelogEntryLike {
  const input = inputFromForm(form);
  const publishedAt = form.date ? `${form.date}T00:00:00.000Z` : saved?.publishedAt ?? now.toISOString();
  return {
    title: input.title || "Untitled entry",
    summary: input.summary,
    body: input.body,
    category: input.category,
    platforms: input.platforms,
    version: input.version,
    publishedAt,
  };
}
