import { createFileRoute } from "@tanstack/react-router";

import { SITE_URL } from "@/lib/site-content";
import { isAppHost } from "@/lib/app-host-rewrite";
import { AI_AGENTS, robotsGroup } from "@/lib/robots-policy";
import { appHostRobots } from "@/server/app-host-files";

/**
 * robots.txt, emitting a `Content-Signal` line (contentsignals.org / AIPREF
 * draft) and explicit per-crawler groups for the major AI bots — policy in
 * lib/robots-policy.ts. app.capturecat.so answers its own (sign-in pages only).
 */

// Nothing under these should be indexed: the dashboard, sign-in, and the API.
const DISALLOW = ["/app", "/login", "/api/"];

const RULES = ["Allow: /", ...DISALLOW.map((path) => `Disallow: ${path}`)];

export const Route = createFileRoute("/robots.txt")({
  server: {
    handlers: {
      GET: ({ request }) => {
        const url = new URL(request.url);
        const body = isAppHost(url.host)
          ? appHostRobots(url.origin)
          : [
              "# CaptureCat, https://capturecat.so",
              "# Content signals: https://contentsignals.org",
              "",
              robotsGroup("*", RULES),
              "",
              ...AI_AGENTS.map((a) => robotsGroup(a, RULES) + "\n"),
              `Sitemap: ${SITE_URL}/sitemap.xml`,
              // ARD spec §6.1: points agents at the capability manifest.
              `Agentmap: ${SITE_URL}/.well-known/ai-catalog.json`,
              "",
            ].join("\n");

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
