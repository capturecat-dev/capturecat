/**
 * The root files of app.capturecat.so — robots.txt, sitemap.xml and
 * llms.txt for the signed-in dashboard host. The same routes answer the
 * marketing site's versions; on the app host they hand off here
 * (lib/app-host-rewrite.ts keeps them off the /app mapping, which bounced
 * them to sign-in).
 *
 * Only the sign-in page and the agent files are public on this host, so
 * that is all these list. The marketing site's discovery documents are
 * served here too (src/server.ts), and its Markdown guide for agents is
 * agent-discovery.ts appHostMarkdown.
 */
import { SITE_URL } from "@/lib/site-content";
import { MCP_ENDPOINT } from "@/lib/agent-access";
import { AI_AGENTS, robotsGroup } from "@/lib/robots-policy";

/** What crawlers may fetch on the app host: sign-in and the agent files. */
const APP_RULES = [
  "Allow: /login",
  "Allow: /index.md",
  "Allow: /login.md",
  "Allow: /llms.txt",
  "Allow: /auth.md",
  "Allow: /.well-known/",
  "Disallow: /",
];

export function appHostRobots(origin: string): string {
  return [
    `# CaptureCat web app, ${origin} — every page needs sign-in.`,
    `# Agents: connect instead of crawling — ${SITE_URL}/auth.md`,
    "# Content signals: https://contentsignals.org",
    "",
    robotsGroup("*", APP_RULES),
    "",
    ...AI_AGENTS.map((agent) => robotsGroup(agent, APP_RULES) + "\n"),
    `Sitemap: ${origin}/sitemap.xml`,
    `Agentmap: ${SITE_URL}/.well-known/ai-catalog.json`,
    "",
  ].join("\n");
}

export function appHostSitemap(origin: string): string {
  return (
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
    `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n  <url>\n    <loc>${origin}/login</loc>\n  </url>\n</urlset>\n`
  );
}

export function appHostLlmsTxt(origin: string): string {
  return [
    "# CaptureCat web app",
    "",
    "> The signed-in CaptureCat dashboard: shared videos, comments, viewer analytics, playlists, cloud projects, team, billing and settings. Every page needs a CaptureCat account; agents reach the same data through the remote MCP server.",
    "",
    "## For agents",
    `- [The web app, for agents](${origin}/index.md): What the dashboard is, how to connect instead of driving it, and what agents may do.`,
    `- [How agents authenticate](${SITE_URL}/auth.md): OAuth 2.1 sign-in (Claude.ai / ChatGPT connectors) or a scoped agent token for the remote MCP server at ${MCP_ENDPOINT}.`,
    `- [Remote MCP server card](${SITE_URL}/.well-known/mcp/server-card.json): Its tools and the scope each needs.`,
    `- [Agent skills](${SITE_URL}/.well-known/agent-skills/index.json): SKILL.md files for the local and remote MCP servers and the Screenshot API.`,
    "",
    "## Everything else",
    `- [CaptureCat](${SITE_URL}/llms.txt): The public site's llms.txt — every page as Markdown.`,
    "",
  ].join("\n");
}
