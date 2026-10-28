import { createFileRoute } from "@tanstack/react-router";

import { SITE_PAGES, SITE_URL } from "@/lib/site-content";
import { CHANGELOG_PATH, changelogEntryPath, fetchAllChangelog } from "@/lib/changelog/site";
import { isAppHost } from "@/lib/app-host-rewrite";
import { appHostSitemap } from "@/server/app-host-files";

/**
 * XML sitemap. Follows Google's current guidance: only <loc> and <lastmod>
 * carry weight (<changefreq>/<priority> are ignored), and lastmod is a real
 * per-page date from the registry, not a build timestamp.
 *
 * The changelog is not in the registry (it lives in D1): /changelog and each
 * published entry are appended from the API, dated by their last edit. If
 * the API is unreachable the sitemap still answers, with /changelog undated.
 * app.capturecat.so lists only its sign-in page (server/app-host-files.ts).
 */
export const Route = createFileRoute("/sitemap.xml")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const self = new URL(request.url);
        if (isAppHost(self.host)) {
          return new Response(appHostSitemap(self.origin), {
            status: 200,
            headers: { "Content-Type": "application/xml; charset=utf-8", "Cache-Control": "public, max-age=3600, s-maxage=86400" },
          });
        }
        const url = (loc: string, lastmod?: string) =>
          `  <url>\n    <loc>${loc}</loc>\n${lastmod ? `    <lastmod>${lastmod}</lastmod>\n` : ""}  </url>`;
        const fetched = await fetchAllChangelog();
        const changelog = fetched ?? [];
        const day = (iso: string) => iso.slice(0, 10);
        const edited = (e: { publishedAt: string; updatedAt: string }) => (e.updatedAt > e.publishedAt ? e.updatedAt : e.publishedAt);
        const newest = changelog.reduce<string | undefined>((max, e) => (!max || edited(e) > max ? edited(e) : max), undefined);

        const urls = [
          ...SITE_PAGES.map((page) => url(`${SITE_URL}${page.path === "/" ? "" : page.path}`, page.lastModified)),
          url(`${SITE_URL}${CHANGELOG_PATH}`, newest && day(newest)),
          ...changelog.map((e) => url(`${SITE_URL}${changelogEntryPath(e.slug)}`, day(edited(e)))),
        ].join("\n");

        const body = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`;

        return new Response(body, {
          status: 200,
          headers: {
            "Content-Type": "application/xml; charset=utf-8",
            // Without the changelog (API unreachable), only briefly.
            "Cache-Control": fetched ? "public, max-age=3600, s-maxage=86400" : "public, max-age=300",
          },
        });
      },
    },
  },
});
