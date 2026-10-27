import { describe, expect, it } from "vitest";

import { AGENT_SKILLS, skillPath } from "@/lib/agent-skills";
import {
  API_CATALOG_PROFILE,
  SKILLS_SCHEMA,
  acceptsHtml,
  agentDiscoveryResponse,
  agentNotFound,
  aiCatalog,
  htmlRenderable,
  sha256Hex,
} from "./agent-discovery";

const get = (path: string, init: RequestInit = {}) => new Request(`https://capturecat.so${path}`, init);

describe("api-catalog (RFC 9727)", () => {
  it("serves a profiled Linkset with service-desc, service-doc and status", async () => {
    const res = (await agentDiscoveryResponse(get("/.well-known/api-catalog")))!;
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe(`application/linkset+json; profile="${API_CATALOG_PROFILE}"`);
    expect(res.headers.get("Link")).toContain('rel="api-catalog"');
    const body = (await res.json()) as { linkset: Array<Record<string, unknown>> };
    expect(body.linkset).toHaveLength(1);
    const entry = body.linkset[0]!;
    expect(entry.anchor).toBe("https://api.capturecat.so/api");
    for (const rel of ["service-desc", "service-doc", "status"]) {
      expect(Array.isArray(entry[rel]) && (entry[rel] as Array<{ href: string }>)[0]!.href).toMatch(/^https:\/\//);
    }
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
    expect(await agentDiscoveryResponse(get("/.well-known/mcp/server-card.json"))).toBeNull();
    expect(await agentDiscoveryResponse(get("/openapi.json", { method: "POST" }))).toBeNull();
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
