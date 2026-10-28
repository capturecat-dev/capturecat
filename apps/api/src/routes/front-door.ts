/**
 * The front doors of api.capturecat.so and mcp.capturecat.so: what an agent
 * (or an agent-readiness scanner such as isitagentready.com) reads before
 * anything else. Both roots used to answer a JSON 404, so a scanner stopped
 * at the door and an agent that typed the bare host learned nothing.
 *
 *   GET /                          an index of where everything is: JSON, or
 *                                  Markdown for Accept: text/markdown
 *   GET /robots.txt                only the index and /.well-known/ are crawlable
 *   GET /sitemap.xml               the index
 *   GET /.well-known/api-catalog   RFC 9727 Linkset — the same two APIs
 *                                  capturecat.so's catalog lists (apps/web
 *                                  src/server/agent-discovery.ts apiCatalog)
 *   GET SITE_DOCUMENTS             302 to the one copy on capturecat.so (auth.md,
 *                                  llms.txt, openapi.json, the skills index and
 *                                  the ai-catalog), the way the MCP server card
 *                                  already redirects (src/mcp/routes.ts)
 *
 * Host-aware: on mcp.capturecat.so the index describes the MCP endpoint, on
 * api.capturecat.so (and a local `wrangler dev`) the REST API. Static and
 * public: no auth, no D1. The MCP host lets exactly these paths through its
 * isolation middleware (index.ts).
 */

import { Hono, type Context } from "hono";
import type { Env, Variables } from "../types";
import { shareBaseURL } from "../lib/origins";
import { mcpResource, oauthIssuer, protectedResourceMetadataUrl } from "../lib/oauth/config";

export const frontDoorRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

export const MCP_HOSTNAME = "mcp.capturecat.so";
export const API_CATALOG_PROFILE = "https://www.rfc-editor.org/info/rfc9727";

const CACHE = "public, max-age=300, s-maxage=3600";

/** = the marketing site's robots.txt policy (apps/web routes/robots[.]txt.ts). */
const CONTENT_SIGNAL = "search=yes, ai-input=yes, ai-train=yes";

/** = the marketing site's per-crawler groups, so each AI bot sees a rule
 *  addressed to it by name. */
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

interface Urls {
  /** This host's own origin (https://api.capturecat.so or https://mcp.capturecat.so). */
  self: string;
  api: string;
  site: string;
  mcp: string;
  serverCard: string;
  asMetadata: string;
  prMetadata: string;
}

function urlsFor(c: Context<{ Bindings: Env; Variables: Variables }>): Urls {
  const site = shareBaseURL(c.env);
  const api = oauthIssuer(c.env);
  return {
    self: new URL(c.req.url).origin,
    api,
    site,
    mcp: mcpResource(c.env),
    serverCard: `${site}/.well-known/mcp/server-card.json`,
    asMetadata: `${api}/.well-known/oauth-authorization-server`,
    prMetadata: protectedResourceMetadataUrl(c.env),
  };
}

const isMcpHost = (c: Context) => new URL(c.req.url).hostname === MCP_HOSTNAME;

export function apiCatalog(u: Pick<Urls, "api" | "site" | "mcp" | "serverCard">) {
  return {
    linkset: [
      {
        anchor: `${u.api}/api`,
        "service-desc": [{ href: `${u.site}/openapi.json`, type: "application/vnd.oai.openapi+json" }],
        "service-doc": [{ href: `${u.site}/docs/api`, type: "text/html" }],
        status: [{ href: `${u.api}/api/health`, type: "application/json" }],
      },
      {
        anchor: u.mcp,
        "service-desc": [{ href: u.serverCard, type: "application/json" }],
        "service-doc": [
          { href: `${u.site}/agents`, type: "text/html" },
          { href: `${u.site}/auth.md`, type: "text/markdown" },
        ],
      },
    ],
  };
}

function apiIndex(u: Urls) {
  return {
    name: "CaptureCat API",
    description:
      "The API behind CaptureCat: the Screenshot API (render any web page to an image), agent-token management for the remote MCP server, the Mac app's release feed, and oEmbed for share links. Cloud agents should use the remote MCP server instead of driving this API directly.",
    documentation: `${u.site}/docs/api`,
    openapi: `${u.site}/openapi.json`,
    api_catalog: `${u.self}/.well-known/api-catalog`,
    health: `${u.api}/api/health`,
    authentication: `${u.site}/auth.md`,
    oauth_authorization_server: u.asMetadata,
    mcp: { endpoint: u.mcp, server_card: u.serverCard, protected_resource_metadata: u.prMetadata },
    llms_txt: `${u.site}/llms.txt`,
  };
}

function mcpIndex(u: Urls) {
  return {
    name: "CaptureCat remote MCP server",
    description:
      "Streamable HTTP MCP server for a CaptureCat account's shared videos: transcripts, AI summaries, comments, analytics, share settings, playlists, cloud-project editing, webhooks and screenshots. Agents ask the owner first before anything becomes visible to others, and can never delete.",
    endpoint: u.mcp,
    transport: "streamable-http",
    server_card: u.serverCard,
    protected_resource_metadata: u.prMetadata,
    authorization_server: u.api,
    authentication: `${u.site}/auth.md`,
    documentation: `${u.site}/agents`,
    api_catalog: `${u.self}/.well-known/api-catalog`,
  };
}

function apiIndexMarkdown(u: Urls): string {
  return [
    "# CaptureCat API",
    "",
    "> The API behind CaptureCat: the Screenshot API, agent-token management for the remote MCP server, the Mac app's release feed, and oEmbed for share links.",
    "",
    "Cloud agents that want to work with someone's CaptureCat videos should connect to the **remote MCP server** rather than call this API directly.",
    "",
    "## Start here",
    "",
    `- Documentation: ${u.site}/docs/api`,
    `- OpenAPI 3.1: ${u.site}/openapi.json`,
    `- API catalog (RFC 9727): ${u.self}/.well-known/api-catalog`,
    `- How to authenticate: ${u.site}/auth.md`,
    `- Health: ${u.api}/api/health`,
    "",
    "## Remote MCP server",
    "",
    `- Endpoint (Streamable HTTP): ${u.mcp}`,
    `- Server card: ${u.serverCard}`,
    `- OAuth protected-resource metadata: ${u.prMetadata}`,
    `- OAuth authorization-server metadata: ${u.asMetadata}`,
    "",
    `Everything else about CaptureCat, as Markdown: ${u.site}/llms.txt`,
    "",
  ].join("\n");
}

function mcpIndexMarkdown(u: Urls): string {
  return [
    "# CaptureCat remote MCP server",
    "",
    `> Streamable HTTP MCP endpoint: ${u.mcp}`,
    "",
    "Work with a CaptureCat account's shared videos: transcripts, AI summaries, comments, analytics, share settings, playlists, cloud-project editing, webhooks and screenshots.",
    "",
    "## Connect",
    "",
    `- **OAuth 2.1 (\"Sign in with CaptureCat\")** — what Claude.ai and ChatGPT custom connectors use. An unauthenticated call to the endpoint answers 401 with \`resource_metadata\`; the protected-resource metadata is at ${u.prMetadata} and the authorization server is ${u.api}.`,
    "- **Agent token** — other clients send `Authorization: Bearer cc_pat_…`, created in Settings → Agent access with chosen scopes and expiry.",
    "",
    "## Rules",
    "",
    "- Agents ask the owner first before anything becomes visible to others (posting a comment, making a video more visible, publishing a share).",
    "- Agents can never delete anything and can't touch billing.",
    "",
    "## More",
    "",
    `- Tools and scopes: ${u.serverCard}`,
    `- How to authenticate: ${u.site}/auth.md`,
    `- Documentation: ${u.site}/agents`,
    "",
  ].join("\n");
}

/** q-value of a media type in an Accept header (0 when absent). */
function acceptQ(accept: string, type: string): number {
  for (const part of accept.split(",")) {
    const [media, ...params] = part.trim().split(";");
    if (media!.trim().toLowerCase() !== type) continue;
    const q = params.map((p) => p.trim()).find((p) => p.startsWith("q="));
    return q ? Number(q.slice(2)) || 0 : 1;
  }
  return 0;
}

/** Markdown when it is asked for at least as much as JSON or HTML. */
function prefersMarkdown(accept: string): boolean {
  const md = acceptQ(accept, "text/markdown");
  return md > 0 && md >= acceptQ(accept, "application/json") && md >= acceptQ(accept, "text/html");
}

function catalogLink(u: Urls): string {
  return `<${u.self}/.well-known/api-catalog>; rel="api-catalog"`;
}

frontDoorRoutes.get("/", (c) => {
  const u = urlsFor(c);
  const mcp = isMcpHost(c);
  const links = [
    catalogLink(u),
    `<${u.site}/auth.md>; rel="describedby"; type="text/markdown"`,
    mcp
      ? `<${u.serverCard}>; rel="service-desc"; type="application/json"`
      : `<${u.site}/openapi.json>; rel="service-desc"; type="application/vnd.oai.openapi+json"`,
    `<${mcp ? `${u.site}/agents` : `${u.site}/docs/api`}>; rel="service-doc"; type="text/html"`,
  ];
  const headers = {
    "Cache-Control": CACHE,
    "Access-Control-Allow-Origin": "*",
    Vary: "Accept",
    Link: links.join(", "),
  };
  if (prefersMarkdown(c.req.header("Accept") ?? "")) {
    return c.body(mcp ? mcpIndexMarkdown(u) : apiIndexMarkdown(u), 200, {
      ...headers,
      "Content-Type": "text/markdown; charset=utf-8",
    });
  }
  return c.json(mcp ? mcpIndex(u) : apiIndex(u), 200, headers);
});

frontDoorRoutes.get("/robots.txt", (c) => {
  const u = urlsFor(c);
  const group = (agent: string) =>
    [`User-agent: ${agent}`, `Content-Signal: ${CONTENT_SIGNAL}`, "Allow: /$", "Allow: /.well-known/", "Disallow: /"].join("\n");
  const body = [
    isMcpHost(c)
      ? `# CaptureCat remote MCP server, ${u.self} — an endpoint for MCP clients, nothing to index.`
      : `# CaptureCat API, ${u.self} — machine endpoints, nothing to index.`,
    `# Docs for people and agents: ${u.site}/llms.txt`,
    "# Content signals: https://contentsignals.org",
    "",
    group("*"),
    "",
    ...AI_AGENTS.map((agent) => `${group(agent)}\n`),
    `Sitemap: ${u.self}/sitemap.xml`,
    // ARD §6.1: the capability manifest lives on the marketing site.
    `Agentmap: ${u.site}/.well-known/ai-catalog.json`,
    "",
  ].join("\n");
  return c.text(body, 200, { "Cache-Control": CACHE });
});

frontDoorRoutes.get("/sitemap.xml", (c) => {
  const u = urlsFor(c);
  const body =
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
    `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n  <url>\n    <loc>${u.self}/</loc>\n  </url>\n</urlset>\n`;
  return c.body(body, 200, { "Content-Type": "application/xml; charset=utf-8", "Cache-Control": CACHE });
});

/** Documents that live on the marketing site; these hosts point there. */
export const SITE_DOCUMENTS = [
  "/auth.md",
  "/llms.txt",
  "/openapi.json",
  "/.well-known/agent-skills/index.json",
  "/.well-known/ai-catalog.json",
];

for (const path of SITE_DOCUMENTS) {
  frontDoorRoutes.get(path, (c) =>
    c.body(null, 302, {
      Location: `${shareBaseURL(c.env)}${path}`,
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": CACHE,
    }),
  );
}

frontDoorRoutes.get("/.well-known/api-catalog", (c) => {
  const u = urlsFor(c);
  return c.body(JSON.stringify(apiCatalog(u), null, 2), 200, {
    "Content-Type": `application/linkset+json; profile="${API_CATALOG_PROFILE}"`,
    "Cache-Control": CACHE,
    "Access-Control-Allow-Origin": "*",
    Link: catalogLink(u),
  });
});
