import { describe, expect, it } from "vitest";

import { changelogEntryMarkdown, changelogMarkdown, changelogRss, demoteHeadings, escapeXml } from "./feeds";
import { formatChangelogDate, groupByMonth, slugify, type ChangelogEntry } from "./model";
import { changelogHead, isChangelogPath } from "./site";

const SITE = { siteUrl: "https://capturecat.so", title: "CaptureCat changelog", description: "What's new." };

function entry(over: Partial<ChangelogEntry> = {}): ChangelogEntry {
  return {
    slug: "agents-share-links",
    title: "Agents can publish share links",
    summary: "An agent asks first, you approve.",
    body: "## Details\n\n- One\n- Two",
    category: "new",
    platforms: ["web", "agents"],
    version: "1.3.1",
    publishedAt: "2026-10-28T09:30:00.000Z",
    updatedAt: "2026-10-28T09:30:00.000Z",
    ...over,
  };
}

describe("model", () => {
  it("slugs titles", () => {
    expect(slugify("Agents can publish share links — and must ask you first")).toBe(
      "agents-can-publish-share-links-and-must-ask-you-first",
    );
    expect(slugify("  Café & Crème 1.3.1!  ")).toBe("cafe-and-creme-1-3-1");
    expect(slugify("x".repeat(200))).toHaveLength(80);
    expect(slugify("¡¡¡")).toBe("");
  });

  it("dates are UTC (server and browser print the same day)", () => {
    expect(formatChangelogDate("2026-10-31T23:30:00.000Z")).toBe("31 October 2026");
    expect(formatChangelogDate("2026-11-01T00:30:00+02:00")).toBe("31 October 2026");
  });

  it("groups by month, keeping order", () => {
    const groups = groupByMonth([
      entry({ slug: "c", publishedAt: "2026-10-28T00:00:00.000Z" }),
      entry({ slug: "b", publishedAt: "2026-10-01T00:00:00.000Z" }),
      entry({ slug: "a", publishedAt: "2026-09-30T00:00:00.000Z" }),
    ]);
    expect(groups.map((g) => [g.label, g.entries.map((e) => e.slug)])).toEqual([
      ["October 2026", ["c", "b"]],
      ["September 2026", ["a"]],
    ]);
  });
});

describe("site", () => {
  it("knows which paths are changelog pages", () => {
    expect(isChangelogPath("/changelog")).toBe(true);
    expect(isChangelogPath("/changelog/agents-share-links")).toBe(true);
    expect(isChangelogPath("/changelog/")).toBe(false);
    expect(isChangelogPath("/changelog/Bad_Slug")).toBe(false);
    expect(isChangelogPath("/changelog.md")).toBe(false);
    expect(isChangelogPath("/changelog/a/b")).toBe(false);
    expect(isChangelogPath("/changelogs")).toBe(false);
  });

  it("heads carry canonical, the Markdown twin and the feed", () => {
    const head = changelogHead({ path: "/changelog/x", title: "X | CaptureCat", description: "d", ogType: "article", noindex: true });
    expect(head.links).toEqual([
      { rel: "canonical", href: "https://capturecat.so/changelog/x" },
      { rel: "alternate", type: "text/markdown", href: "/changelog/x.md" },
      { rel: "alternate", type: "application/rss+xml", title: "CaptureCat changelog", href: "https://capturecat.so/changelog.xml" },
    ]);
    expect(head.meta).toContainEqual({ name: "robots", content: "noindex, follow" });
    expect(head.meta).toContainEqual({ property: "og:type", content: "article" });
  });
});

describe("Markdown twin", () => {
  it("puts body headings under the entry's, as the page does; fences untouched", () => {
    expect(demoteHeadings("# A\n## B\n### C\n```\n# code\n```\n###### F\n#tag", 3)).toBe(
      "#### A\n#### B\n##### C\n```\n# code\n```\n##### F\n#tag",
    );
    expect(demoteHeadings("## B\n### C", 1)).toBe("## B\n### C");
  });

  it("lists every entry under its month", () => {
    const md = changelogMarkdown(
      [entry(), entry({ slug: "older", title: "Older fix", category: "fixed", version: null, platforms: [], publishedAt: "2026-09-02T00:00:00.000Z", body: "" })],
      SITE,
    );
    expect(md).toContain("# CaptureCat changelog\n\n> What's new.");
    expect(md).toContain("## October 2026\n\n### Agents can publish share links\n\n_28 October 2026 · v1.3.1 · New · Web, Agents_ · [Permalink](https://capturecat.so/changelog/agents-share-links)");
    expect(md).toContain("#### Details\n\n- One\n- Two");
    expect(md).toContain("## September 2026\n\n### Older fix\n\n_2 September 2026 · Fixed_");
    expect(changelogMarkdown([], SITE)).toContain("No entries yet.");
  });

  it("renders one entry with a way back", () => {
    const md = changelogEntryMarkdown(entry(), SITE);
    expect(md.startsWith("# Agents can publish share links\n")).toBe(true);
    expect(md).toContain("\n## Details\n");
    expect(md).toContain("[All updates](https://capturecat.so/changelog)");
  });
});

describe("RSS", () => {
  it("is escaped XML with the page's HTML inside", () => {
    const xml = changelogRss(
      [
        entry({
          title: "Fix <b> & \"quotes\"",
          summary: "Ends the <script> bug",
          body: "Text <script>alert(1)</script> [site](https://example.com)\u0007",
        }),
      ],
      SITE,
    );
    expect(xml.startsWith('<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0"')).toBe(true);
    expect(xml).toContain("<title>Fix &lt;b&gt; &amp; &quot;quotes&quot; (v1.3.1)</title>");
    expect(xml).toContain('<guid isPermaLink="true">https://capturecat.so/changelog/agents-share-links</guid>');
    expect(xml).toContain("<pubDate>Wed, 28 Oct 2026 09:30:00 GMT</pubDate>");
    expect(xml).toContain("<category>New</category>\n      <category>Web</category>\n      <category>Agents</category>");
    // HTML-escaped by the renderer, then XML-escaped: never a live tag.
    expect(xml).toContain("&amp;lt;script&amp;gt;alert(1)&amp;lt;/script&amp;gt;");
    expect(xml).toContain("&lt;a href=&quot;https://example.com/&quot; rel=&quot;noopener noreferrer&quot;&gt;site&lt;/a&gt;");
    expect(xml).not.toMatch(/<script|\u0007/);
    expect(xml.match(/<item>/g)).toHaveLength(1);
  });

  it("an empty feed is still a valid channel", () => {
    const xml = changelogRss([], SITE);
    expect(xml).toContain("<channel>");
    expect(xml).not.toContain("<item>");
    expect(xml).not.toContain("lastBuildDate");
  });

  it("strips characters XML 1.0 forbids", () => {
    expect(escapeXml("a\u0000b\u001Fc\ttab\nline")).toBe("abc\ttab\nline");
  });
});
