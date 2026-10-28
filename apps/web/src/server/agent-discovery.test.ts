import { describe, expect, it } from "vitest";

import { AGENT_SKILLS, skillPath } from "@/lib/agent-skills";
import {
  API_CATALOG_PROFILE,
  SKILLS_SCHEMA,
  acceptsHtml,
  agentDiscoveryResponse,
  agentNotFound,
  aiCatalog,
  appHostMarkdown,
  appHostMarkdownResponse,
  htmlRenderable,
  mcpServerCard,
  poppyManifest,
  sha256Hex,
} from "./agent-discovery";
import { appHostLlmsTxt, appHostRobots, appHostSitemap } from "./app-host-files";
import { AGENT_SCOPES, MCP_ENDPOINT, MCP_TOOLS } from "@/lib/agent-access";

const get = (path: string, init: RequestInit = {}) => new Request(`https://capturecat.so${path}`, init);

describe("api-catalog (RFC 9727)", () => {
  it("serves a profiled Linkset with service-desc, service-doc and status", async () => {
    const res = (await agentDiscoveryResponse(get("/.well-known/api-catalog")))!;
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe(`application/linkset+json; profile="${API_CATALOG_PROFILE}"`);
    expect(res.headers.get("Link")).toContain('rel="api-catalog"');
    const body = (await res.json()) as { linkset: Array<Record<string, unknown>> };
    // The REST API and the remote MCP server — the same two the API Worker's
    // own catalog lists (apps/api routes/front-door.ts).
    expect(body.linkset.map((e) => e.anchor)).toEqual(["https://api.capturecat.so/api", MCP_ENDPOINT]);
    const entry = body.linkset[0]!;
    for (const rel of ["service-desc", "service-doc", "status"]) {
      expect(Array.isArray(entry[rel]) && (entry[rel] as Array<{ href: string }>)[0]!.href).toMatch(/^https:\/\//);
    }
    const mcp = body.linkset[1] as { "service-desc": Array<{ href: string }> };
    expect(mcp["service-desc"][0]!.href).toBe("https://capturecat.so/.well-known/mcp/server-card.json");
  });

  it("answers HEAD with the Link header and no body (§3)", async () => {
    const res = (await agentDiscoveryResponse(get("/.well-known/api-catalog", { method: "HEAD" })))!;
    expect(res.status).toBe(200);
    expect(res.headers.get("Link")).toContain('rel="api-catalog"');
    expect(await res.text()).toBe("");
  });
});

describe("ai-catalog (ARD)", () => {
  it("follows the structure the spec requires", async () => {
    const res = (await agentDiscoveryResponse(get("/.well-known/ai-catalog.json")))!;
    expect(res.headers.get("Content-Type")).toMatch(/^application\/json/);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
    const cat = aiCatalog();
    expect(cat.specVersion).toBeTruthy();
    expect(cat.host).toMatchObject({ displayName: "CaptureCat", identifier: "did:web:capturecat.so" });
    expect(cat.entries.length).toBeGreaterThan(0);
    for (const entry of cat.entries as Array<Record<string, unknown>>) {
      expect(entry.identifier).toMatch(/^urn:air:capturecat\.so:[a-z0-9-]+:[a-z0-9-]+$/);
      expect(entry.displayName).toBeTruthy();
      expect(entry.type).toMatch(/^[a-z]+\/[a-z0-9.+-]+$/);
      expect(("url" in entry ? 1 : 0) + ("data" in entry ? 1 : 0)).toBe(1);
      const queries = entry.representativeQueries as string[];
      expect(queries.length).toBeGreaterThanOrEqual(2);
      expect(queries.length).toBeLessThanOrEqual(5);
    }
  });
});

describe("remote MCP server", () => {
  it("is in the ai-catalog, pointing at its server card", () => {
    const entry = (aiCatalog().entries as Array<Record<string, unknown>>).find(
      (e) => e.identifier === "urn:air:capturecat.so:mcp:capturecat-remote",
    );
    expect(entry).toMatchObject({ type: "application/json", url: "https://capturecat.so/.well-known/mcp/server-card.json" });
    expect(String(entry!.description)).toContain("https://mcp.capturecat.so/mcp");
  });

  it("serves the server card: remote transport, bearer agent tokens, every tool with its scope", async () => {
    const res = (await agentDiscoveryResponse(get("/.well-known/mcp/server-card.json")))!;
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toMatch(/^application\/json/);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
    const card = (await res.json()) as ReturnType<typeof mcpServerCard>;
    expect(card).toEqual(JSON.parse(JSON.stringify(mcpServerCard())));
    expect(MCP_ENDPOINT).toBe("https://mcp.capturecat.so/mcp");
    expect(card.transport).toEqual({ type: "streamable-http", url: MCP_ENDPOINT });
    expect(card.remotes).toEqual([{ type: "streamable-http", url: MCP_ENDPOINT }]);
    expect(card.authentication).toMatchObject({
      required: true,
      schemes: ["oauth2", "bearer"],
      scopes: [...AGENT_SCOPES],
      oauth2: {
        protectedResourceMetadata: "https://mcp.capturecat.so/.well-known/oauth-protected-resource",
        authorizationServer: "https://api.capturecat.so",
      },
    });
    expect(card.tools.map((t) => t.name)).toEqual(MCP_TOOLS.map((t) => t.name));
    for (const tool of card.tools) expect(AGENT_SCOPES).toContain(tool.requiredScope);
  });

  it("names the MCP host in auth.md and the remote skill", async () => {
    const auth = await (await agentDiscoveryResponse(get("/auth.md")))!.text();
    expect(auth).toContain("https://mcp.capturecat.so/mcp");
    expect(auth).toContain("Authorization: Bearer cc_pat_");
    // OAuth for Claude.ai / ChatGPT connectors, and where to discover it.
    expect(auth).toContain("Claude.ai and ChatGPT custom connectors work with no token");
    expect(auth).toContain("https://mcp.capturecat.so/.well-known/oauth-protected-resource");
    expect(auth).toContain("https://api.capturecat.so/.well-known/oauth-authorization-server");
    expect(auth).toContain("code_challenge_method=S256");
    expect(auth).toContain("approval_required");
    expect(auth).toContain("webhook-signature");
    const skill = AGENT_SKILLS.find((s) => s.name === "capturecat-remote");
    expect(skill?.markdown).toContain("claude mcp add --transport http capturecat https://mcp.capturecat.so/mcp");
  });
});

describe("agent skills index (v0.2.0)", () => {
  it("lists every skill with a digest of the exact served bytes", async () => {
    const res = (await agentDiscoveryResponse(get("/.well-known/agent-skills/index.json")))!;
    const index = (await res.json()) as { $schema: string; skills: Array<Record<string, string>> };
    expect(index.$schema).toBe(SKILLS_SCHEMA);
    expect(index.skills).toHaveLength(AGENT_SKILLS.length);
    for (const entry of index.skills) {
      expect(entry.name).toMatch(/^[a-z0-9]+(-[a-z0-9]+)*$/);
      expect(entry.type).toBe("skill-md");
      expect(entry.description).toBeTruthy();
      const served = (await agentDiscoveryResponse(get(new URL(entry.url!).pathname)))!;
      expect(served.headers.get("Content-Type")).toMatch(/^text\/markdown/);
      expect(entry.digest).toBe(`sha256:${await sha256Hex(await served.text())}`);
    }
  });

  it("each SKILL.md has front matter naming itself", () => {
    for (const skill of AGENT_SKILLS) {
      expect(skill.markdown.startsWith(`---\nname: ${skill.name}\ndescription: ${skill.description}\n---\n`)).toBe(true);
      expect(skillPath(skill.name)).toBe(`/.well-known/agent-skills/${skill.name}/SKILL.md`);
    }
  });
});

describe("openapi.json and auth.md", () => {
  it("serves the OpenAPI document as JSON", async () => {
    const res = (await agentDiscoveryResponse(get("/openapi.json")))!;
    expect(res.headers.get("Content-Type")).toMatch(/^application\/json/);
    expect(((await res.json()) as { openapi: string }).openapi).toBe("3.1.0");
  });

  it("serves auth.md with an H1 containing auth.md", async () => {
    const res = (await agentDiscoveryResponse(get("/auth.md")))!;
    expect(res.headers.get("Content-Type")).toMatch(/^text\/markdown/);
    expect((await res.text()).split("\n")[0]).toMatch(/^# .*auth\.md/);
  });

  it("falls through for everything else and for non-GET methods", async () => {
    expect(await agentDiscoveryResponse(get("/pricing"))).toBeNull();
    expect(await agentDiscoveryResponse(get("/openapi.json", { method: "POST" }))).toBeNull();
  });
});

describe("OAuth pointers", () => {
  it("redirects the OAuth well-known paths to the hosts they describe, with CORS", async () => {
    for (const host of ["capturecat.so", "app.capturecat.so"]) {
      const as = (await agentDiscoveryResponse(new Request(`https://${host}/.well-known/oauth-authorization-server`)))!;
      expect(as.status, host).toBe(307);
      expect(as.headers.get("Location")).toBe("https://api.capturecat.so/.well-known/oauth-authorization-server");
      expect(as.headers.get("Access-Control-Allow-Origin")).toBe("*");
      const pr = (await agentDiscoveryResponse(new Request(`https://${host}/.well-known/oauth-protected-resource`)))!;
      expect(pr.status, host).toBe(307);
      expect(pr.headers.get("Location")).toBe("https://mcp.capturecat.so/.well-known/oauth-protected-resource");
    }
    // No OIDC issuer: not even a pointer.
    expect(await agentDiscoveryResponse(get("/.well-known/openid-configuration"))).toBeNull();
  });
});

describe("Personal Agent Protocol (poppy.json)", () => {
  it("declares the remote MCP server behind the OAuth issuer, and every scope with a hint", async () => {
    const res = (await agentDiscoveryResponse(get("/.well-known/poppy.json")))!;
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toMatch(/^application\/json/);
    const body = (await res.json()) as ReturnType<typeof poppyManifest>;
    expect(body).toMatchObject({
      protocol_version: "0.1",
      organization: { name: "CaptureCat", domain: "capturecat.so" },
      auth: { issuer: "https://api.capturecat.so" },
      apis: [{ type: "mcp", url: MCP_ENDPOINT }],
      web: {},
    });
    expect(Object.keys(body.auth.scopes).sort()).toEqual([...AGENT_SCOPES].sort());
    expect(Object.keys(body.auth.scope_hints).sort()).toEqual([...AGENT_SCOPES].sort());
    // Declares no Poppy conversation endpoint and no browser sessions: neither exists.
    expect(body).not.toHaveProperty("agent");
  });

  it("is only served on the domain it names", async () => {
    expect(await agentDiscoveryResponse(new Request("https://app.capturecat.so/.well-known/poppy.json"))).toBeNull();
  });
});

describe("app.capturecat.so for agents", () => {
  it("has a Markdown guide that sends agents to the MCP server and states the rules", async () => {
    const md = appHostMarkdown();
    expect(md.split("\n")[0]).toBe("# CaptureCat web app");
    expect(md).toContain(MCP_ENDPOINT);
    expect(md).toContain("https://capturecat.so/auth.md");
    expect(md).toContain("ask the owner first");
    const res = appHostMarkdownResponse(new Request("https://app.capturecat.so/login.md"));
    expect(res.headers.get("Content-Type")).toBe("text/markdown; charset=utf-8");
    expect(res.headers.get("Vary")).toBe("Accept");
    expect(res.headers.get("Link")).toContain('rel="api-catalog"');
    const head = appHostMarkdownResponse(new Request("https://app.capturecat.so/index.md", { method: "HEAD" }));
    expect(await head.text()).toBe("");
  });

  it("robots.txt leaves only sign-in and the agent files crawlable, with signals for every AI bot", () => {
    const robots = appHostRobots("https://app.capturecat.so");
    expect(robots).toContain("User-agent: *\nContent-Signal: search=yes, ai-input=yes, ai-train=yes\nAllow: /login\n");
    expect(robots).toContain("Allow: /.well-known/\nDisallow: /");
    for (const bot of ["GPTBot", "ClaudeBot", "PerplexityBot"]) expect(robots).toContain(`User-agent: ${bot}\n`);
    expect(robots).toContain("Sitemap: https://app.capturecat.so/sitemap.xml");
  });

  it("sitemap.xml lists sign-in and llms.txt points at the guide", () => {
    expect(appHostSitemap("https://app.capturecat.so")).toContain("<loc>https://app.capturecat.so/login</loc>");
    const llms = appHostLlmsTxt("https://app.capturecat.so");
    expect(llms.split("\n")[0]).toBe("# CaptureCat web app");
    expect(llms).toContain("https://app.capturecat.so/index.md");
    expect(llms).toContain("https://capturecat.so/llms.txt");
  });
});

describe("agent-friendly 404s", () => {
  it("answers Markdown when Markdown is preferred, with links onward", async () => {
    const res = agentNotFound(get("/nope", { headers: { Accept: "text/markdown" } }))!;
    expect(res.status).toBe(404);
    expect(res.headers.get("Content-Type")).toBe("text/markdown; charset=utf-8");
    const body = await res.text();
    expect(body.length).toBeGreaterThan(20);
    expect(body).toContain("https://capturecat.so/llms.txt");
    expect(body).toContain("https://capturecat.so/sitemap.xml");
  });

  it("answers JSON to an Accept without HTML, and leaves browsers alone", async () => {
    const json = agentNotFound(get("/nope", { headers: { Accept: "application/json" } }))!;
    expect(json.status).toBe(404);
    expect(((await json.json()) as { error: string }).error).toBe("not_found");
    expect(agentNotFound(get("/nope", { headers: { Accept: "text/html,application/xhtml+xml,*/*;q=0.8" } }))).toBeNull();
    expect(agentNotFound(get("/nope", { headers: { Accept: "text/markdown;q=0.5, text/html" } }))).toBeNull();
  });

  it("only rewrites Accept for requests the page renderer would refuse", () => {
    expect(acceptsHtml(null)).toBe(true);
    expect(acceptsHtml("*/*")).toBe(true);
    expect(acceptsHtml("text/markdown")).toBe(false);
    const original = get("/x", { headers: { Accept: "text/html" } });
    expect(htmlRenderable(original)).toBe(original);
    expect(htmlRenderable(get("/x", { headers: { Accept: "application/linkset+json" } })).headers.get("Accept")).toBe("text/html");
  });
});
