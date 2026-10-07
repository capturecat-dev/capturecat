import { describe, expect, it } from "vitest";

import { ALL_DOCS, DOC_SECTIONS, DOC_SITE_PAGES, findDoc, headingId, type DocBlock } from "./index";

/**
 * Structural lint for /docs. Content is hand-written by several authors, so
 * the things that silently break SEO or navigation are checked here: slug
 * shape and uniqueness, every internal link resolving, search-result-sized
 * descriptions, and no duplicate anchors on a page.
 */

function texts(blocks: DocBlock[]): string[] {
  return blocks.flatMap((b) => {
    switch (b.type) {
      case "p":
      case "h2":
      case "h3":
        return [b.text];
      case "list":
        return b.items;
      case "steps":
        return b.steps.flatMap((s) => [s.title, s.text]);
      case "code":
        return b.caption ? [b.caption] : [];
      case "callout":
        return [b.text];
      case "table":
        return b.rows.flat();
      case "shortcuts":
        return b.rows.map(([, a]) => a);
    }
  });
}

describe("docs", () => {
  it("has content", () => {
    expect(ALL_DOCS.length).toBeGreaterThan(0);
  });

  it.each(ALL_DOCS.map((d) => [d.page.slug, d] as const))("%s is well formed", (_slug, { page, section }) => {
    expect(page.slug).toMatch(/^[a-z0-9]+(?:-[a-z0-9]+)*(?:\/[a-z0-9]+(?:-[a-z0-9]+)*)*$/);
    expect(page.slug === section.id || page.slug.startsWith(`${section.id}/`)).toBe(true);
    expect(page.description.length, "description ≤ 160 chars").toBeLessThanOrEqual(160);
    expect(page.description.length, "description ≥ 70 chars").toBeGreaterThanOrEqual(70);
    expect(page.title.length).toBeLessThanOrEqual(70);
    expect(page.lastModified).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(page.blocks.length).toBeGreaterThan(0);

    for (const r of page.related ?? []) expect(findDoc(r), `related "${r}"`).toBeDefined();

    const all = [page.summary, ...texts(page.blocks), ...(page.faqs ?? []).map((f) => f.answer)];
    for (const t of all) {
      for (const [, href] of t.matchAll(/\]\((\/docs\/[^)#\s]+)/g)) {
        expect(findDoc(href.replace(/^\/docs\//, "")), `link ${href}`).toBeDefined();
      }
      // `<account-id>`-style placeholders inside code spans are fine.
      expect(t.replace(/`[^`]*`/g, ""), "no raw HTML").not.toMatch(/<\/?[a-z][^>]*>/i);
    }

    const ids = page.blocks.filter((b) => b.type === "h2" || b.type === "h3").map((b) => headingId(b as never));
    expect(new Set(ids).size, "duplicate heading anchors").toBe(ids.length);
  });

  it("slugs are unique and every section is non-empty", () => {
    const slugs = ALL_DOCS.map((d) => d.page.slug);
    expect(new Set(slugs).size).toBe(slugs.length);
    for (const s of DOC_SECTIONS) expect(s.pages.length).toBeGreaterThan(0);
  });

  it("registers every page for the sitemap and Markdown twins", () => {
    expect(DOC_SITE_PAGES.map((p) => p.path)).toEqual(["/docs", ...ALL_DOCS.map((d) => `/docs/${d.page.slug}`)]);
  });
});
