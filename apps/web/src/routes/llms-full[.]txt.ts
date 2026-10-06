import { createFileRoute } from "@tanstack/react-router";

import { SITE_PAGES, SITE_URL } from "@/lib/site-content";

/**
 * /llms-full.txt: every public page's Markdown twin in one file, so an agent
 * can load the whole site (features, pricing, every guide and comparison) in
 * a single fetch. Same registry as llms.txt, so it never lists a dead page.
 */
export const Route = createFileRoute("/llms-full.txt")({
  server: {
    handlers: {
      GET: () => {
        const body = SITE_PAGES.map(
          (page) =>
            `<!-- page: ${SITE_URL}${page.path === "/" ? "" : page.path} · updated ${page.lastModified} -->\n\n${page.markdown.trim()}\n`
        ).join("\n\n---\n\n");

        return new Response(body, {
          status: 200,
          headers: {
            "Content-Type": "text/plain; charset=utf-8",
            "Cache-Control": "public, max-age=3600, s-maxage=86400",
          },
        });
      },
    },
  },
});
