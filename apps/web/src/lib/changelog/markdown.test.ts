import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { ChangelogMarkdown, markdownToHtml, parseInline, parseMarkdown, safeHref } from "./markdown";

/**
 * The changelog renderer is the only thing between an admin-written body and
 * the public page, so the safety properties are pinned here: raw HTML is
 * text, only http(s) URLs become links, and nothing pathological hangs SSR.
 */

const html = (source: string, headingBase = 2) =>
  renderToStaticMarkup(createElement(ChangelogMarkdown, { source, headingBase }));

/** Tags and text only: what the page and the feed must agree on. */
const skeleton = (markup: string) =>
  markup
    .replace(/^<div[^>]*>|<\/div>$/g, "")
    .replace(/<(\/?[a-z0-9]+)(?:\s[^>]*)?>/g, "<$1>")
    .replace(/\n/g, "")
    .replace(/<\/?div>/g, "");

describe("safety", () => {
  it("shows raw HTML as text", () => {
    const out = html('Hi <script>alert(1)</script> and <img src=x onerror="alert(2)">\n\n<iframe src="https://evil.example"></iframe>');
    expect(out).not.toMatch(/<script|<img|<iframe/i);
    expect(out).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
    expect(out).toContain("&lt;img src=x onerror=");
    expect(markdownToHtml("<b>x</b> <script>y</script>")).toBe("<p>&lt;b&gt;x&lt;/b&gt; &lt;script&gt;y&lt;/script&gt;</p>");
  });

  it.each([
    "javascript:alert(1)",
    "JavaScript:alert(1)",
    "java\tscript:alert(1)",
    " javascript:alert(1)",
    "data:text/html,<script>alert(1)</script>",
    "vbscript:msgbox(1)",
    "/docs/agents",
    "//evil.example/x",
    "mailto:someone@example.com",
    "#top",
  ])("never links %s", (href) => {
    const out = html(`[click me](${href})`);
    expect(out).not.toContain("<a");
    expect(out).toContain("click me");
    expect(safeHref(href)).toBeNull();
  });

  it("links http(s), off-site in a new tab with rel=noopener", () => {
    expect(html("[Stripe](https://stripe.com/docs)")).toContain(
      '<a href="https://stripe.com/docs" class="',
    );
    expect(html("[Stripe](https://stripe.com/docs)")).toMatch(/target="_blank" rel="noopener noreferrer">Stripe<\/a>/);
    const own = html("[docs](https://capturecat.so/docs/agents)");
    expect(own).toContain('href="https://capturecat.so/docs/agents"');
    expect(own).not.toContain("target=");
    expect(markdownToHtml("[x](http://example.com/a?b=1&c=2)")).toBe(
      '<p><a href="http://example.com/a?b=1&amp;c=2" rel="noopener noreferrer">x</a></p>',
    );
  });

  it("cannot break out of the href attribute", () => {
    const out = html('[x](https://example.com/"onmouseover=alert(1))');
    expect(out).not.toMatch(/"\s*onmouseover/);
    expect(out).toContain("https://example.com/%22onmouseover=alert(1)");
  });

  it("escapes code", () => {
    expect(html("`<b>`")).toContain("<code");
    expect(html("`<b>`")).toContain("&lt;b&gt;</code>");
    const block = html("```html\n<script>alert(1)</script>\n```");
    expect(block).toContain("<pre");
    expect(block).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
    expect(block).not.toContain("<script");
  });

  it("stays fast and finite on pathological input", () => {
    const inputs = [
      "*a".repeat(20_000),
      "_a ".repeat(20_000),
      "**a".repeat(15_000),
      "[".repeat(40_000),
      "[a](".repeat(10_000),
      "`a".repeat(20_000),
      ">".repeat(20_000) + " deep",
      Array.from({ length: 2_000 }, (_, i) => `${" ".repeat(i % 40)}- item`).join("\n"),
    ];
    for (const input of inputs) {
      const started = performance.now();
      expect(() => html(input)).not.toThrow();
      expect(performance.now() - started, input.slice(0, 12)).toBeLessThan(1_500);
    }
  });
});

describe("Markdown subset", () => {
  it("headings sit under the page's own heading", () => {
    expect(skeleton(html("# A\n\n## B\n\n### C", 2))).toBe("<h2>A</h2><h2>B</h2><h3>C</h3>");
    expect(skeleton(html("# A\n\n### C", 4))).toBe("<h4>A</h4><h5>C</h5>");
    expect(skeleton(html("##### deep", 6))).toBe("<h6>deep</h6>");
    expect(skeleton(html("#hashtag"))).toBe("<p>#hashtag</p>");
  });

  it("emphasis, code and escapes", () => {
    expect(skeleton(html("**bold** and *it* and _it_ and `x`"))).toBe(
      "<p><strong>bold</strong> and <em>it</em> and <em>it</em> and <code>x</code></p>",
    );
    expect(skeleton(html("snake_case_name stays"))).toBe("<p>snake_case_name stays</p>");
    expect(skeleton(html("2 * 3 * 4"))).toBe("<p>2 * 3 * 4</p>");
    expect(skeleton(html("\\*not em\\*"))).toBe("<p>*not em*</p>");
    expect(skeleton(html("*a **b** c*"))).toBe("<p><em>a <strong>b</strong> c</em></p>");
    expect(skeleton(html("**[link](https://example.com)**"))).toBe('<p><strong><a>link</a></strong></p>');
  });

  it("lists: bullets, numbers, nesting, continuation", () => {
    expect(skeleton(html("- one\n- two\n  - two.a\n  - two.b\n- three"))).toBe(
      "<ul><li>one</li><li>two<ul><li>two.a</li><li>two.b</li></ul></li><li>three</li></ul>",
    );
    expect(skeleton(html("1. first\n2. second\n3. third"))).toBe("<ol><li>first</li><li>second</li><li>third</li></ol>");
    expect(html("3. three\n4. four")).toContain('<ol class="');
    expect(html("3. three\n4. four")).toContain('start="3"');
    expect(skeleton(html("- a\nlazy line\n\n- b"))).toBe("<ul><li>a\nlazy line</li><li>b</li></ul>".replace("\n", ""));
    expect(skeleton(html("Intro\n- a\n- b"))).toBe("<p>Intro</p><ul><li>a</li><li>b</li></ul>");
    // Only a list starting at 1 may interrupt a paragraph (CommonMark).
    expect(skeleton(html("We shipped a lot in\n2024. It was busy"))).toBe("<p>We shipped a lot in2024. It was busy</p>");
  });

  it("quotes, rules, fences, paragraphs", () => {
    expect(skeleton(html("> quoted **text**\n> more"))).toBe("<blockquote><p>quoted <strong>text</strong>more</p></blockquote>");
    expect(skeleton(html("a\n\n---\n\nb"))).toBe("<p>a</p><hr><p>b</p>");
    expect(skeleton(html("~~~\n# not a heading\n~~~"))).toBe("<pre><code># not a heading</code></pre>");
    expect(skeleton(html("```js\nconst a = 1;\n"))).toBe("<pre><code>const a = 1;\n</code></pre>".replace("\n", ""));
    expect(skeleton(html("```inline```"))).toBe("<p><code>inline</code></p>");
    expect(parseMarkdown("")).toEqual([]);
    expect(html("")).toBe("");
  });

  it("the feed's HTML is the page's tree", () => {
    const source = [
      "# Heading",
      "Some **bold**, *em*, `code` and a [link](https://example.com).",
      "",
      "- one",
      "- two",
      "  1. nested",
      "",
      "> quote",
      "",
      "```",
      "code <b>",
      "```",
      "",
      "---",
    ].join("\n");
    expect(skeleton(markdownToHtml(source))).toBe(skeleton(html(source)));
  });

  it("link text keeps its formatting, links never nest", () => {
    expect(parseInline("[**a** [b](https://x.test)](https://y.test)")).toEqual([
      {
        type: "link",
        href: "https://y.test/",
        external: true,
        children: [
          { type: "strong", children: [{ type: "text", text: "a" }] },
          { type: "text", text: " [b](https://x.test)" },
        ],
      },
    ]);
  });
});
