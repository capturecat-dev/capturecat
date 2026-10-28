/**
 * The bare hosts' front door (routes/front-door.ts) through the REAL Worker
 * entry, so the MCP host's isolation middleware is part of what is tested:
 * api.capturecat.so and mcp.capturecat.so both answer /, robots.txt,
 * sitemap.xml and the api-catalog, and the MCP host still serves nothing of
 * the REST API.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1 } from "../test-support/d1-sqlite.js";
import { MemoryBucket } from "../test-support/memory-bucket";

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));
vi.mock("../lib/auth", () => import("../test-support/fake-session"));
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined, delete: async () => true } });
vi.stubGlobal("fetch", vi.fn(async () => {
  throw new Error("offline test: unexpected fetch");
}));

const { default: worker } = await import("../index");

const API = "https://api.capturecat.so";
const MCP = "https://mcp.capturecat.so";
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

let env: Env;
beforeEach(() => {
  env = {
    DB: createTestD1(),
    R2: new MemoryBucket(),
    BETTER_AUTH_URL: API,
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
  } as unknown as Env;
});

const get = (url: string, headers: Record<string, string> = {}) =>
  worker.fetch(new Request(url, { headers, redirect: "manual" }), env, ctx);

describe("front door", () => {
  it("each host's root is an index with agent-useful Link relations", async () => {
    const api = await get(`${API}/`);
    expect(api.status).toBe(200);
    expect(api.headers.get("Content-Type")).toContain("application/json");
    expect(api.headers.get("Link")).toContain(`<${API}/.well-known/api-catalog>; rel="api-catalog"`);
    expect(api.headers.get("Link")).toContain('<https://capturecat.so/openapi.json>; rel="service-desc"');
    expect(await api.json()).toMatchObject({
      name: "CaptureCat API",
      openapi: "https://capturecat.so/openapi.json",
      mcp: { endpoint: `${MCP}/mcp` },
    });

    const mcp = await get(`${MCP}/`);
    expect(mcp.status).toBe(200);
    expect(mcp.headers.get("Link")).toContain(`<${MCP}/.well-known/api-catalog>; rel="api-catalog"`);
    expect(mcp.headers.get("Link")).toContain('<https://capturecat.so/.well-known/mcp/server-card.json>; rel="service-desc"');
    expect(await mcp.json()).toMatchObject({
      endpoint: `${MCP}/mcp`,
      protected_resource_metadata: `${MCP}/.well-known/oauth-protected-resource`,
      authorization_server: API,
    });
  });

  it("serves the index as Markdown to agents that ask for it, JSON to everyone else", async () => {
    for (const host of [API, MCP]) {
      const md = await get(`${host}/`, { Accept: "text/markdown, text/html;q=0.9" });
      expect(md.headers.get("Content-Type"), host).toBe("text/markdown; charset=utf-8");
      expect(md.headers.get("Vary")).toBe("Accept");
      expect(await md.text()).toMatch(/^# CaptureCat /);

      const browser = await get(`${host}/`, { Accept: "text/html,application/xhtml+xml,*/*;q=0.8" });
      expect(browser.headers.get("Content-Type"), host).toContain("application/json");
    }
  });

  it("robots.txt leaves only the index and /.well-known/ crawlable, with content signals and AI-bot groups", async () => {
    for (const host of [API, MCP]) {
      const res = await get(`${host}/robots.txt`);
      expect(res.status, host).toBe(200);
      expect(res.headers.get("Content-Type")).toContain("text/plain");
      const body = await res.text();
      expect(body).toContain("User-agent: *\nContent-Signal: search=yes, ai-input=yes, ai-train=yes\nAllow: /$\nAllow: /.well-known/\nDisallow: /");
      expect(body).toContain("User-agent: ClaudeBot");
      expect(body).toContain("User-agent: GPTBot");
      expect(body).toContain(`Sitemap: ${host}/sitemap.xml`);
    }
  });

  it("sitemap.xml lists the host's index", async () => {
    const res = await get(`${MCP}/sitemap.xml`);
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/xml; charset=utf-8");
    expect(await res.text()).toContain(`<loc>${MCP}/</loc>`);
  });

  it("the api-catalog is an RFC 9727 linkset listing the REST API and the MCP server", async () => {
    for (const host of [API, MCP]) {
      const res = await get(`${host}/.well-known/api-catalog`);
      expect(res.status, host).toBe(200);
      expect(res.headers.get("Content-Type")).toBe('application/linkset+json; profile="https://www.rfc-editor.org/info/rfc9727"');
      const body = (await res.json()) as { linkset: Array<{ anchor: string }> };
      expect(body.linkset.map((l) => l.anchor)).toEqual([`${API}/api`, `${MCP}/mcp`]);
    }
  });

  it("points the marketing site's agent documents at their one copy on capturecat.so", async () => {
    for (const host of [API, MCP]) {
      for (const path of ["/auth.md", "/llms.txt", "/openapi.json", "/.well-known/agent-skills/index.json", "/.well-known/ai-catalog.json"]) {
        const res = await get(`${host}${path}`);
        expect(res.status, `${host}${path}`).toBe(302);
        expect(res.headers.get("Location")).toBe(`https://capturecat.so${path}`);
      }
    }
  });

  it("the MCP host still serves none of the REST API", async () => {
    for (const path of ["/api/health", "/api/me", "/api/changelog", "/api/releases/latest"]) {
      expect((await get(`${MCP}${path}`)).status, path).toBe(404);
    }
  });
});
