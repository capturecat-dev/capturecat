import { createFileRoute } from "@tanstack/react-router";

import { changelogRss } from "@/lib/changelog/feeds";
import { CHANGELOG_DESCRIPTION, fetchChangelog } from "@/lib/changelog/site";
import { SITE_URL } from "@/lib/site-content";

/**
 * /changelog.xml — RSS 2.0 of the latest 50 published entries. Each item's
 * HTML (`content:encoded`) comes from the page's own escaped renderer.
 * An API outage is a 503 rather than an empty feed, so readers keep what
 * they have instead of seeing every entry vanish.
 */
export const Route = createFileRoute("/changelog.xml")({
  server: {
    handlers: {
      GET: async () => {
        const page = await fetchChangelog({ limit: 50 });
        if (!page) {
          return new Response("Changelog temporarily unavailable\n", {
            status: 503,
            headers: { "Content-Type": "text/plain; charset=utf-8", "Retry-After": "120" },
          });
        }
        const body = changelogRss(page.entries, {
          siteUrl: SITE_URL,
          title: "CaptureCat changelog",
          description: CHANGELOG_DESCRIPTION,
        });
        return new Response(body, {
          status: 200,
          headers: {
            "Content-Type": "application/rss+xml; charset=utf-8",
            "Cache-Control": "public, max-age=300, s-maxage=600",
          },
        });
      },
    },
  },
});
