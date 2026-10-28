import { createFileRoute } from "@tanstack/react-router";

import { SITE_PAGES, SITE_URL } from "@/lib/site-content";
import { changelogMarkdown } from "@/lib/changelog/feeds";
import { CHANGELOG_DESCRIPTION, fetchAllChangelog } from "@/lib/changelog/site";

/**
 * /llms-full.txt: every public page's Markdown twin in one file, so an agent
 * can load the whole site (features, pricing, every guide and comparison) in
 * a single fetch. Same registry as llms.txt, so it never lists a dead page.
 * The changelog (D1, not the registry) is appended from the API — its last
 * 50 entries — and simply left out while the API is unreachable.
 */
export const Route = createFileRoute("/llms-full.txt")({
  server: {
    handlers: {
      GET: async () => {
        const pages = SITE_PAGES.map(
          (page) =>
            `<!-- page: ${SITE_URL}${page.path === "/" ? "" : page.path} · updated ${page.lastModified} -->\n\n${page.markdown.trim()}\n`
        );
        const changelog = await fetchAllChangelog(50);
        if (changelog?.length) {
          const site = { siteUrl: SITE_URL, title: "CaptureCat changelog", description: CHANGELOG_DESCRIPTION };
          pages.push(
            `<!-- page: ${SITE_URL}/changelog · updated ${changelog[0].publishedAt.slice(0, 10)} -->\n\n${changelogMarkdown(changelog, site).trim()}\n`
          );
        }
        const body = pages.join("\n\n---\n\n");

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
