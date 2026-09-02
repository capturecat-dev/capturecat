import { createFileRoute } from "@tanstack/react-router";

import { SITE_PAGES, SITE_URL } from "@/lib/site-content";

/**
 * XML sitemap. Follows Google's current guidance: only <loc> and <lastmod>
 * carry weight (<changefreq>/<priority> are ignored), and lastmod is a real
 * per-page date from the registry, not a build timestamp.
 */
export const Route = createFileRoute("/sitemap.xml")({
  server: {
    handlers: {
      GET: () => {
        const urls = SITE_PAGES.map((page) => {
          const loc = `${SITE_URL}${page.path === "/" ? "" : page.path}`;
          return `  <url>\n    <loc>${loc}</loc>\n    <lastmod>${page.lastModified}</lastmod>\n  </url>`;
        }).join("\n");

        const body = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`;

        return new Response(body, {
          status: 200,
          headers: {
            "Content-Type": "application/xml; charset=utf-8",
            "Cache-Control": "public, max-age=3600, s-maxage=86400",
          },
        });
      },
    },
  },
});
