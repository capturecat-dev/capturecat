import { createFileRoute } from "@tanstack/react-router";

import { SITE_URL } from "@/lib/site-content";

/**
 * robots.txt, emitting a `Content-Signal` line (contentsignals.org / AIPREF
 * draft) and explicit per-crawler groups for the major AI bots.
 *
 * Content policy, adjust to taste: search, agent-answering, and training are
 * all allowed. Change `CONTENT_SIGNAL` to flip any of them.
 */
const CONTENT_SIGNAL = "search=yes, ai-input=yes, ai-train=yes";

// Nothing under these should be indexed: the dashboard, sign-in, and the API.
const DISALLOW = ["/app", "/login", "/api/"];

// Explicit groups so each AI crawler sees a rule addressed to it by name.
const AI_AGENTS = [
  "GPTBot",
  "OAI-SearchBot",
  "ChatGPT-User",
  "ClaudeBot",
  "Claude-Web",
  "anthropic-ai",
  "Claude-SearchBot",
  "Google-Extended",
  "PerplexityBot",
  "CCBot",
  "Applebot-Extended",
  "Meta-ExternalAgent",
];

function group(agent: string, includeSignal: boolean): string {
  const lines = [`User-agent: ${agent}`];
  if (includeSignal) lines.push(`Content-Signal: ${CONTENT_SIGNAL}`);
  lines.push("Allow: /");
  for (const path of DISALLOW) lines.push(`Disallow: ${path}`);
  return lines.join("\n");
}

export const Route = createFileRoute("/robots.txt")({
  server: {
    handlers: {
      GET: () => {
        const body = [
          "# CaptureCat, https://capturecat.so",
          "# Content signals: https://contentsignals.org",
          "",
          group("*", true),
          "",
          ...AI_AGENTS.map((a) => group(a, true) + "\n"),
          `Sitemap: ${SITE_URL}/sitemap.xml`,
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
