import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import {
  AGENT_SCOPES,
  DEFAULT_SCOPES,
  MCP_TOOLS,
  MCP_ENDPOINT,
  SCOPE_GROUPS,
  SCOPE_INFO,
  claudeMcpAddCommand,
  describeExpiry,
  isWriteScope,
  mcpJsonConfig,
  relativeTime,
  sortTokens,
  tokenStatus,
  type AgentTokenSummary,
} from "./agent-access";

const TOKEN = `cc_pat_${"A1b2".repeat(10)}`;

describe("scopes", () => {
  it("match the API's list exactly (apps/api/src/lib/agent-tokens.ts)", () => {
    const source = readFileSync(fileURLToPath(new URL("../../../api/src/lib/agent-tokens.ts", import.meta.url)), "utf8");
    const block = /export const AGENT_SCOPES = \[([\s\S]*?)\] as const;/.exec(source)?.[1];
    expect(block, "AGENT_SCOPES not found in the API source").toBeTruthy();
    const apiScopes = [...block!.matchAll(/"([^"]+)"/g)].map((m) => m[1]);
    expect([...AGENT_SCOPES]).toEqual(apiScopes);
  });

  it("the documented tools match the API's registry (apps/api/src/mcp/tools.ts)", () => {
    const source = readFileSync(fileURLToPath(new URL("../../../api/src/mcp/tools.ts", import.meta.url)), "utf8");
    // `const ident = defineTool({ name: "…", …, scope: "…", … })`, then the
    // TOOLS array's order of those identifiers (= tools/list order).
    const byIdent = new Map(
      [...source.matchAll(/const (\w+) = defineTool\(\{\s*name: "([a-z_]+)",[\s\S]*?scope: "([a-z:]+)",/g)].map((m) => [
        m[1],
        { name: m[2], scope: m[3] },
      ]),
    );
    const order = /export const TOOLS: ToolDefinition\[\] = \[([\s\S]*?)\]/.exec(source)?.[1] ?? "";
    const registry = [...order.matchAll(/(\w+),/g)].map((m) => byIdent.get(m[1]));
    expect(registry.length).toBeGreaterThan(0);
    expect(MCP_TOOLS.map(({ name, scope }) => ({ name, scope }))).toEqual(registry);
  });

  it("every scope is labelled and shown in exactly one group", () => {
    const grouped = SCOPE_GROUPS.flatMap((g) => g.scopes);
    expect([...grouped].sort()).toEqual([...AGENT_SCOPES].sort());
    for (const scope of AGENT_SCOPES) expect(SCOPE_INFO[scope].label).toBeTruthy();
  });

  it("defaults to read-only", () => {
    expect(DEFAULT_SCOPES.some(isWriteScope)).toBe(false);
    expect(isWriteScope("comments:write")).toBe(true);
    expect(isWriteScope("screenshots")).toBe(true);
  });
});

describe("snippets", () => {
  it("claude mcp add points at the MCP host with the bearer header", () => {
    expect(MCP_ENDPOINT).toBe("https://mcp.capturecat.so/mcp");
    expect(claudeMcpAddCommand(TOKEN)).toBe(
      `claude mcp add --transport http capturecat https://mcp.capturecat.so/mcp --header "Authorization: Bearer ${TOKEN}"`,
    );
  });

  it("the JSON config is valid JSON with the same endpoint and header", () => {
    expect(JSON.parse(mcpJsonConfig(TOKEN))).toEqual({
      mcpServers: {
        capturecat: { type: "http", url: MCP_ENDPOINT, headers: { Authorization: `Bearer ${TOKEN}` } },
      },
    });
  });
});

describe("status and time", () => {
  const now = new Date("2026-10-28T12:00:00.000Z");
  const token = (over: Partial<AgentTokenSummary>): AgentTokenSummary => ({
    id: "t",
    name: "t",
    prefix: "cc_pat_abcdefgh",
    scopes: [],
    createdAt: "2026-10-01T00:00:00.000Z",
    expiresAt: null,
    lastUsedAt: null,
    revokedAt: null,
    ...over,
  });

  it("revoked beats expired beats active", () => {
    expect(tokenStatus(token({}), now)).toBe("active");
    expect(tokenStatus(token({ expiresAt: "2026-10-27T00:00:00.000Z" }), now)).toBe("expired");
    expect(tokenStatus(token({ expiresAt: "2026-10-27T00:00:00.000Z", revokedAt: "2026-10-20T00:00:00.000Z" }), now)).toBe("revoked");
  });

  it("sorts active tokens first, newest first", () => {
    const sorted = sortTokens(
      [
        token({ id: "old", createdAt: "2026-09-01T00:00:00.000Z" }),
        token({ id: "revoked", createdAt: "2026-10-20T00:00:00.000Z", revokedAt: "2026-10-21T00:00:00.000Z" }),
        token({ id: "new", createdAt: "2026-10-10T00:00:00.000Z" }),
      ],
      now,
    );
    expect(sorted.map((t) => t.id)).toEqual(["new", "old", "revoked"]);
  });

  it("describes times the way the list shows them", () => {
    expect(relativeTime("2026-10-28T11:59:40.000Z", now)).toBe("just now");
    expect(relativeTime("2026-10-28T11:55:00.000Z", now)).toBe("5 min ago");
    expect(relativeTime("2026-10-28T09:00:00.000Z", now)).toBe("3 h ago");
    expect(relativeTime("2026-10-27T12:00:00.000Z", now)).toBe("1 day ago");
    expect(describeExpiry(null, now)).toBe("never expires");
    expect(describeExpiry("2026-11-09T12:00:00.000Z", now)).toBe("expires in 12 days");
    expect(describeExpiry("2026-10-25T12:00:00.000Z", now)).toBe("expired 3 days ago");
  });
});
