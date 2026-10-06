import { canonicalUrl, findPageByPath } from "@/lib/site-content";

/**
 * Shared Markdown renderer for the public pages.
 *
 * The public URL is `/{path}.md` (e.g. /pricing.md, /index.md); server.ts
 * rewrites those onto the internal `/md/*` route. Content is served from the
 * single site-content registry, so HTML and Markdown never drift.
 */
export function markdownPageResponse(path: string): Response {
  const page = findPageByPath(path);

  if (!page) {
    return new Response("# Not found\n\nNo Markdown rendering for this path.\n", {
      status: 404,
      headers: { "Content-Type": "text/markdown; charset=utf-8" },
    });
  }

  // Prepend canonical + source so a stand-alone Markdown file is self-describing.
  const canonical = canonicalUrl(page.path);
  const header = `<!-- canonical: ${canonical} -->\n\n`;
  return new Response(header + page.markdown, {
    status: 200,
    headers: {
      "Content-Type": "text/markdown; charset=utf-8",
      "Cache-Control": "public, max-age=300, s-maxage=3600",
      // The twin is for agents; the HTML page is what search engines should
      // index. A canonical Link header is how Google consolidates non-HTML
      // duplicates onto the original.
      Link: `<${canonical}>; rel="canonical"`,
      "X-Robots-Tag": "all",
    },
  });
}
