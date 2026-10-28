/**
 * Machine-readable discovery files for agents, served by the web Worker
 * before the TanStack handler (src/server.ts). Each follows its published
 * format exactly; the scanner that audits them is isitagentready.com.
 *
 *   /.well-known/api-catalog            RFC 9727 Linkset (application/linkset+json)
 *   /.well-known/ai-catalog.json        ARD / ai-catalog manifest (CORS *)
 *   /.well-known/mcp/server-card.json   MCP server card (SEP-2127) for the REMOTE
 *                                       server at https://mcp.capturecat.so/mcp
 *                                       (mcp.capturecat.so's own well-known path
 *                                       redirects here)
 *   /.well-known/agent-skills/index.json   Agent Skills Discovery RFC v0.2.0
 *   /.well-known/agent-skills/<name>/SKILL.md
 *   /openapi.json                       OpenAPI 3.1 for api.capturecat.so
 *   /auth.md                            how agents authenticate (OAuth "Sign in with
 *                                       CaptureCat" and agent tokens for the remote
 *                                       MCP server, access keys for the Screenshot API)
 *   /.well-known/poppy.json             Personal Agent Protocol 0.1 discovery
 *                                       (capturecat.so only: it names its domain)
 *
 * The OAuth documents are NOT served from this origin: they belong to the
 * hosts they describe — RFC 9728 protected-resource metadata on
 * mcp.capturecat.so, RFC 8414 authorization-server metadata on
 * api.capturecat.so (both from the API Worker, apps/api/src/routes/oauth.ts).
 * Their well-known paths here REDIRECT there, so an agent that starts from
 * the brand domain finds them without this origin serving a document whose
 * issuer or resource names another host. There is no OIDC issuer.
 *
 * Every file above is served on app.capturecat.so too (src/server.ts), except
 * poppy.json; that host also gets its own Markdown guide (appHostMarkdown).
 *
 * Also here: agent-friendly 404s. TanStack Start answers an unmatched path
 * with 500 "Only HTML requests are supported here" when the Accept header
 * has no text/html — every agent asking for JSON or Markdown got a 500.
 */
import { AGENT_SKILLS, skillPath } from "@/lib/agent-skills";
import { AUTH_MD } from "@/lib/auth-md";
import { AGENT_SCOPES, MCP_ENDPOINT, MCP_TOOLS, SCOPE_INFO, type AgentScope } from "@/lib/agent-access";
import { OPENAPI_DOCUMENT } from "@/lib/openapi";
import { SITE_URL } from "@/lib/site-url";

const API_ORIGIN = "https://api.capturecat.so";
const MCP_ORIGIN = new URL(MCP_ENDPOINT).origin;
// Hostname, not host: a port is not valid in a `did:web` or `urn:air` id.
const HOST = new URL(SITE_URL).hostname;

/** Where the OAuth well-known paths on this origin point (see the header). */
export const OAUTH_POINTERS: Record<string, string> = {
  "/.well-known/oauth-authorization-server": `${API_ORIGIN}/.well-known/oauth-authorization-server`,
  "/.well-known/oauth-protected-resource": `${MCP_ORIGIN}/.well-known/oauth-protected-resource`,
};

export const API_CATALOG_PROFILE = "https://www.rfc-editor.org/info/rfc9727";
export const SKILLS_SCHEMA = "https://schemas.agentskills.io/discovery/0.2.0/schema.json";
export const SERVER_CARD_PATH = "/.well-known/mcp/server-card.json";

/** RFC 9727 §3: the api-catalog relation, sent on GET and HEAD. */
export const API_CATALOG_LINK = `<${SITE_URL}/.well-known/api-catalog>; rel="api-catalog"`;

/** The same two APIs the API Worker's own catalog lists on api. and mcp.
 *  (apps/api src/routes/front-door.ts apiCatalog). */
export function apiCatalog() {
  return {
    linkset: [
      {
        anchor: `${API_ORIGIN}/api`,
        "service-desc": [{ href: `${SITE_URL}/openapi.json`, type: "application/vnd.oai.openapi+json" }],
        "service-doc": [{ href: `${SITE_URL}/docs/api`, type: "text/html" }],
        status: [{ href: `${API_ORIGIN}/api/health`, type: "application/json" }],
      },
      {
        anchor: MCP_ENDPOINT,
        "service-desc": [{ href: `${SITE_URL}${SERVER_CARD_PATH}`, type: "application/json" }],
        "service-doc": [
          { href: `${SITE_URL}/agents`, type: "text/html" },
          { href: `${SITE_URL}/auth.md`, type: "text/markdown" },
        ],
      },
    ],
  };
}

/** How much a scope can change, for Poppy's scope_hints (§3.1): reads
 *  change nothing; every write is undoable by the owner (agents can't
 *  delete, edits are versions, comments and webhooks can be removed). */
const SCOPE_HINTS: Record<AgentScope, { changes: "none" | "reversible"; personal_data: boolean }> = {
  "account:read": { changes: "none", personal_data: true },
  "videos:read": { changes: "none", personal_data: true },
  "videos:write": { changes: "reversible", personal_data: true },
  "comments:read": { changes: "none", personal_data: true },
  "comments:write": { changes: "reversible", personal_data: true },
  "analytics:read": { changes: "none", personal_data: true },
  "playlists:read": { changes: "none", personal_data: true },
  "playlists:write": { changes: "reversible", personal_data: true },
  screenshots: { changes: "none", personal_data: false },
  "webhooks:write": { changes: "reversible", personal_data: true },
  "projects:read": { changes: "none", personal_data: true },
  "projects:write": { changes: "reversible", personal_data: true },
};

/**
 * Personal Agent Protocol (Poppy) 0.1 discovery, §3.1. Declares only what is
 * real: the remote MCP server (an `mcp` API: Streamable HTTP, 2025-06-18+,
 * tokens bound to its own URL as resource) behind the OAuth issuer on
 * api.capturecat.so, whose RFC 8414 metadata binds this domain back
 * (`protected_resources` / `poppy_domains`, apps/api routes/oauth.ts). No
 * Poppy conversation endpoint (`agent`) and no browser-session endpoint —
 * `web: {}` means personal agents browse the site signed out.
 */
export function poppyManifest() {
  return {
    protocol_version: "0.1",
    organization: { name: "CaptureCat", domain: HOST },
    auth: {
      issuer: API_ORIGIN,
      scopes: Object.fromEntries(AGENT_SCOPES.map((scope) => [scope, SCOPE_INFO[scope].description])),
      scope_hints: SCOPE_HINTS,
    },
    apis: [
      {
        type: "mcp",
        url: MCP_ENDPOINT,
        description:
          "Your CaptureCat videos: transcripts, AI summaries, comments, analytics, share settings, playlists, cloud-project edits, webhooks and screenshots. Asks the owner before anything becomes visible to others; never deletes.",
      },
    ],
    web: {},
  };
}

/**
 * app.capturecat.so as Markdown: what the signed-in dashboard is and how an
 * agent should reach the same data without driving it. Served for /, /login
 * and their .md twins on the app host (src/server.ts) — public text only,
 * never anything from the visitor's account.
 */
export function appHostMarkdown(): string {
  return [
    "# CaptureCat web app",
    "",
    "> app.capturecat.so is the signed-in CaptureCat dashboard: your shared videos, comments, viewer analytics, playlists, cloud projects, team, billing and settings. Every page needs a CaptureCat account.",
    "",
    "## For AI agents",
    "",
    "Connect to CaptureCat directly instead of driving this dashboard in a browser:",
    "",
    `- **Remote MCP server:** ${MCP_ENDPOINT} (Streamable HTTP). Claude.ai, ChatGPT and other custom-connector clients sign in with OAuth 2.1 ("Sign in with CaptureCat"), discovered from the 401's \`resource_metadata\`. Other clients send a scoped agent token (\`Authorization: Bearer cc_pat_…\`) the account owner creates in Settings → Agent access.`,
    `- **How authentication works:** ${SITE_URL}/auth.md`,
    `- **Tools and the scopes they need:** ${SITE_URL}${SERVER_CARD_PATH}`,
    `- **Agent skills:** ${SITE_URL}/.well-known/agent-skills/index.json`,
    `- **Record and edit on a Mac** (the Mac app's local MCP server): ${SITE_URL}/agents.md`,
    "",
    "In a browser that supports WebMCP, the signed-in dashboard registers tools for the owner's videos, transcripts, analytics and account (`list_my_videos`, `search_my_transcripts`, `get_video_analytics`, `get_my_account`, `set_video_privacy`, `open_dashboard_page`).",
    "",
    "## What agents may do",
    "",
    "- Agents ask the owner first before anything becomes visible to others: posting a comment, making a video more visible, publishing a share. The owner approves or declines at app.capturecat.so/approvals/<id>.",
    "- Agents can never delete anything, and can't touch billing.",
    "",
    "## Pages (sign-in required)",
    "",
    "- `/` — your videos",
    "- `/approvals/<id>` — approve or decline a request from an agent",
    "- `/oauth/authorize` — the consent page apps reach through \"Sign in with CaptureCat\"",
    "- `/projects` — cloud projects for the web editor",
    "- `/settings` — account, agent access and webhooks",
    "- `/billing` — plan and invoices",
    "",
    `The public site, every page as Markdown: ${SITE_URL}/llms.txt`,
    "",
  ].join("\n");
}

export function aiCatalog() {
  return {
    specVersion: "1.0",
    host: { displayName: "CaptureCat", identifier: `did:web:${HOST}` },
    entries: [
      {
        identifier: `urn:air:${HOST}:api:capturecat-api`,
        displayName: "CaptureCat API",
        description:
          "Screenshot rendering for any URL, agent-token management for the remote MCP server, plus the public release feed and oEmbed for CaptureCat share links.",
        type: "application/vnd.oai.openapi+json",
        url: `${SITE_URL}/openapi.json`,
        representativeQueries: [
          "take a full-page screenshot of a web page",
          "render a URL to a PNG or WebP image",
          "get the latest CaptureCat for Mac download",
          "embed a CaptureCat share video",
        ],
      },
      {
        identifier: `urn:air:${HOST}:mcp:capturecat-remote`,
        displayName: "CaptureCat remote MCP server",
        description:
          `Streamable HTTP MCP server at ${MCP_ENDPOINT} for cloud agents: list shared videos, read transcripts, summaries, comments and analytics, post comments, change share settings, manage playlists, edit cloud projects, register webhooks and take screenshots. Claude.ai and ChatGPT custom connectors connect with OAuth 2.1 ("Sign in with CaptureCat", PKCE, discovered from the 401's resource_metadata); other clients can send a scoped agent token (Authorization: Bearer cc_pat_…). Agents ask the owner first before posting comments or making a video more visible.`,
        type: "application/json",
        url: `${SITE_URL}${SERVER_CARD_PATH}`,
        representativeQueries: [
          "connect Claude to my CaptureCat videos",
          "add CaptureCat as a ChatGPT connector",
          "summarize the comments on my latest CaptureCat video",
          "which of my screen recordings mention pricing",
          "make my CaptureCat share link private",
        ],
      },
      {
        identifier: `urn:air:${HOST}:mcp:capturecat-mac`,
        displayName: "CaptureCat MCP server (local, macOS)",
        description:
          "The MCP server inside the CaptureCat Mac app (stdio): record the screen and edit, restyle and export recordings.",
        type: "text/markdown",
        url: `${SITE_URL}/agents.md`,
        representativeQueries: [
          "record my Mac screen and make a demo video",
          "add zooms and captions to a screen recording",
          "blur an API key in a screen recording",
          "export a vertical clip of a screen recording",
        ],
      },
      {
        identifier: `urn:air:${HOST}:skills:index`,
        displayName: "CaptureCat agent skills",
        description: "SKILL.md instructions for the CaptureCat MCP servers (local and remote) and the Screenshot API.",
        type: "application/json",
        url: `${SITE_URL}/.well-known/agent-skills/index.json`,
        representativeQueries: [
          "how do I connect an agent to CaptureCat",
          "how do I call the CaptureCat screenshot API",
        ],
      },
      {
        identifier: `urn:air:${HOST}:docs:llms-txt`,
        displayName: "CaptureCat llms.txt",
        description: "Index of every public page as Markdown, with when-to-use guidance for agents.",
        type: "text/plain",
        url: `${SITE_URL}/llms.txt`,
        representativeQueries: [
          "what is CaptureCat",
          "which Mac screen recorder edits recordings automatically",
          "CaptureCat pricing and features",
        ],
      },
    ],
  };
}

/**
 * MCP server card for the remote server (SEP-2127 shape). Tools are listed
 * from lib/agent-access.ts, which a test keeps equal to the API's registry;
 * full schemas come from tools/list once a client is authenticated.
 */
export function mcpServerCard() {
  return {
    $schema: "https://static.modelcontextprotocol.io/schemas/mcp-server-card/v1.json",
    version: "1.0",
    protocolVersions: ["2026-07-28", "2025-11-25", "2025-06-18"],
    serverInfo: { name: "capturecat", title: "CaptureCat", version: "1.0.0" },
    description:
      "The CaptureCat account's shared screen-recording videos for cloud agents: list and inspect videos, read transcripts, AI summaries, comments and viewer analytics, post comments as the owner, change share-page settings, manage playlists, and render web-page screenshots. No delete or billing tools.",
    iconUrl: `${SITE_URL}/icon.png`,
    documentationUrl: `${SITE_URL}/agents`,
    transport: { type: "streamable-http", url: MCP_ENDPOINT },
    remotes: [{ type: "streamable-http", url: MCP_ENDPOINT }],
    capabilities: { tools: {} },
    authentication: {
      required: true,
      schemes: ["oauth2", "bearer"],
      description:
        "OAuth 2.1 (\"Sign in with CaptureCat\"): authorization code + PKCE S256, Client ID Metadata Documents or Dynamic Client Registration, resource indicator https://mcp.capturecat.so/mcp — what Claude.ai and ChatGPT custom connectors use. Or a personal agent token (cc_pat_…) in Authorization: Bearer, created in Settings → Agent access with chosen scopes and expiry. Either can be revoked at any time.",
      oauth2: {
        protectedResourceMetadata: "https://mcp.capturecat.so/.well-known/oauth-protected-resource",
        authorizationServer: "https://api.capturecat.so",
        authorizationServerMetadata: "https://api.capturecat.so/.well-known/oauth-authorization-server",
      },
      scopes: [...AGENT_SCOPES],
      documentation: `${SITE_URL}/auth.md`,
    },
    tools: MCP_TOOLS.map((tool) => ({ name: tool.name, description: tool.summary, requiredScope: tool.scope })),
  };
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function skillsIndex() {
  return {
    $schema: SKILLS_SCHEMA,
    skills: await Promise.all(
      AGENT_SKILLS.map(async (skill) => ({
        name: skill.name,
        type: "skill-md",
        description: skill.description,
        url: `${SITE_URL}${skillPath(skill.name)}`,
        digest: `sha256:${await sha256Hex(skill.markdown)}`,
      })),
    ),
  };
}

const CACHE = "public, max-age=300, s-maxage=3600";

function json(body: unknown, contentType = "application/json; charset=utf-8", extra: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status: 200,
    headers: { "Content-Type": contentType, "Cache-Control": CACHE, ...extra },
  });
}

function markdown(body: string): Response {
  return new Response(body, {
    status: 200,
    headers: { "Content-Type": "text/markdown; charset=utf-8", "Cache-Control": CACHE, "Access-Control-Allow-Origin": "*" },
  });
}

const CORS = { "Access-Control-Allow-Origin": "*" };

/** A discovery document for this path, or null to fall through. GET/HEAD only. */
export async function agentDiscoveryResponse(request: Request): Promise<Response | null> {
  if (request.method !== "GET" && request.method !== "HEAD") return null;
  const { pathname: path, hostname } = new URL(request.url);
  let response: Response | null = null;

  const pointer = OAUTH_POINTERS[path];
  if (pointer) {
    return new Response(null, {
      status: 307,
      headers: { Location: pointer, "Cache-Control": CACHE, ...CORS },
    });
  }

  if (path === "/.well-known/poppy.json") {
    // Its organization.domain must equal the host it is served from.
    if (hostname === HOST) response = json(poppyManifest(), "application/json; charset=utf-8", CORS);
  } else if (path === "/.well-known/api-catalog") {
    response = json(apiCatalog(), `application/linkset+json; profile="${API_CATALOG_PROFILE}"`, {
      ...CORS,
      Link: API_CATALOG_LINK,
    });
  } else if (path === "/.well-known/ai-catalog.json") {
    response = json(aiCatalog(), "application/json; charset=utf-8", CORS);
  } else if (path === SERVER_CARD_PATH) {
    response = json(mcpServerCard(), "application/json; charset=utf-8", CORS);
  } else if (path === "/.well-known/agent-skills/index.json") {
    response = json(await skillsIndex(), "application/json; charset=utf-8", CORS);
  } else if (path === "/openapi.json") {
    response = json(OPENAPI_DOCUMENT, "application/json; charset=utf-8", { ...CORS, Link: API_CATALOG_LINK });
  } else if (path === "/auth.md") {
    response = markdown(AUTH_MD);
  } else {
    const skill = AGENT_SKILLS.find((s) => skillPath(s.name) === path);
    if (skill) response = markdown(skill.markdown);
  }

  if (response && request.method === "HEAD") {
    return new Response(null, { status: response.status, headers: response.headers });
  }
  return response;
}

/** The app host's Markdown guide (appHostMarkdown) as a response. */
export function appHostMarkdownResponse(request: Request): Response {
  const response = markdown(appHostMarkdown());
  response.headers.set("Vary", "Accept");
  response.headers.set("Link", API_CATALOG_LINK);
  if (request.method === "HEAD") return new Response(null, { status: 200, headers: response.headers });
  return response;
}

/** q-value of a media type in an Accept header (0 when absent). */
export function acceptQ(accept: string, type: string): number {
  for (const part of accept.split(",")) {
    const [media, ...params] = part.trim().split(";");
    if (media!.trim().toLowerCase() !== type) continue;
    const q = params.map((p) => p.trim()).find((p) => p.startsWith("q="));
    return q ? Number(q.slice(2)) || 0 : 1;
  }
  return 0;
}

/** Whether TanStack Start will render this request at all (it refuses
 *  anything whose Accept names neither text/html nor a wildcard). */
export function acceptsHtml(accept: string | null): boolean {
  if (!accept) return true;
  return acceptQ(accept, "text/html") > 0 || acceptQ(accept, "*/*") > 0 || acceptQ(accept, "text/*") > 0;
}

/** The request the TanStack handler can render: same request, but an Accept
 *  it understands. Only the page renderer sees this copy. */
export function htmlRenderable(request: Request): Request {
  if (acceptsHtml(request.headers.get("accept"))) return request;
  const headers = new Headers(request.headers);
  headers.set("Accept", "text/html");
  return new Request(request, { headers });
}

const NOT_FOUND_LINKS = [
  `- Documentation: ${SITE_URL}/docs`,
  `- Every page as Markdown: ${SITE_URL}/llms.txt`,
  `- Sitemap: ${SITE_URL}/sitemap.xml`,
  `- API (OpenAPI 3.1): ${SITE_URL}/openapi.json`,
];

/**
 * A 404 an agent can read, chosen by what it asked for: Markdown for
 * text/markdown, JSON for an Accept without HTML, else null (keep the HTML
 * page). Status stays 404 either way.
 */
export function agentNotFound(request: Request): Response | null {
  const accept = request.headers.get("accept") ?? "";
  const path = new URL(request.url).pathname;
  const md = acceptQ(accept, "text/markdown");
  if (md > 0 && md >= acceptQ(accept, "text/html")) {
    const body = [
      "# Page not found",
      "",
      `There is no page at \`${path}\` on capturecat.so. It may have moved, or the link may be mistyped.`,
      "",
      "Try one of these instead:",
      "",
      ...NOT_FOUND_LINKS,
      "",
    ].join("\n");
    return new Response(body, {
      status: 404,
      headers: { "Content-Type": "text/markdown; charset=utf-8", "Cache-Control": "no-store" },
    });
  }
  if (!acceptsHtml(accept)) {
    return new Response(
      JSON.stringify({
        error: "not_found",
        message: `There is no resource at ${path} on capturecat.so.`,
        docs: `${SITE_URL}/docs`,
        llms: `${SITE_URL}/llms.txt`,
        openapi: `${SITE_URL}/openapi.json`,
      }),
      { status: 404, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" } },
    );
  }
  return null;
}
