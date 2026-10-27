/**
 * Machine-readable discovery files for agents, served by the web Worker
 * before the TanStack handler (src/server.ts). Each follows its published
 * format exactly; the scanner that audits them is isitagentready.com.
 *
 *   /.well-known/api-catalog            RFC 9727 Linkset (application/linkset+json)
 *   /.well-known/ai-catalog.json        ARD / ai-catalog manifest (CORS *)
 *   /.well-known/agent-skills/index.json   Agent Skills Discovery RFC v0.2.0
 *   /.well-known/agent-skills/<name>/SKILL.md
 *   /openapi.json                       OpenAPI 3.1 for api.capturecat.so
 *   /auth.md                            how agents authenticate (self-contained;
 *                                       there is no OAuth server for third parties)
 *
 * Deliberately NOT published, because they would be false today:
 *   /.well-known/mcp/server-card.json   SEP-2127 cards describe REMOTE servers
 *                                       only; CaptureCat's MCP server is local stdio.
 *   /.well-known/oauth-*, openid-configuration   no third-party OAuth/OIDC issuer.
 *
 * Also here: agent-friendly 404s. TanStack Start answers an unmatched path
 * with 500 "Only HTML requests are supported here" when the Accept header
 * has no text/html — every agent asking for JSON or Markdown got a 500.
 */
import { AGENT_SKILLS, skillPath } from "@/lib/agent-skills";
import { AUTH_MD } from "@/lib/auth-md";
import { OPENAPI_DOCUMENT } from "@/lib/openapi";
import { SITE_URL } from "@/lib/site-url";

const API_ORIGIN = "https://api.capturecat.so";
// Hostname, not host: a port is not valid in a `did:web` or `urn:air` id.
const HOST = new URL(SITE_URL).hostname;

export const API_CATALOG_PROFILE = "https://www.rfc-editor.org/info/rfc9727";
export const SKILLS_SCHEMA = "https://schemas.agentskills.io/discovery/0.2.0/schema.json";

/** RFC 9727 §3: the api-catalog relation, sent on GET and HEAD. */
export const API_CATALOG_LINK = `<${SITE_URL}/.well-known/api-catalog>; rel="api-catalog"`;

export function apiCatalog() {
  return {
    linkset: [
      {
        anchor: `${API_ORIGIN}/api`,
        "service-desc": [{ href: `${SITE_URL}/openapi.json`, type: "application/vnd.oai.openapi+json" }],
        "service-doc": [{ href: `${SITE_URL}/docs/api`, type: "text/html" }],
        status: [{ href: `${API_ORIGIN}/api/health`, type: "application/json" }],
      },
    ],
  };
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
          "Screenshot rendering for any URL, plus the public release feed and oEmbed for CaptureCat share links.",
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
        description: "SKILL.md instructions for the CaptureCat MCP server and the Screenshot API.",
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
  const path = new URL(request.url).pathname;
  let response: Response | null = null;

  if (path === "/.well-known/api-catalog") {
    response = json(apiCatalog(), `application/linkset+json; profile="${API_CATALOG_PROFILE}"`, {
      ...CORS,
      Link: API_CATALOG_LINK,
    });
  } else if (path === "/.well-known/ai-catalog.json") {
    response = json(aiCatalog(), "application/json; charset=utf-8", CORS);
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
