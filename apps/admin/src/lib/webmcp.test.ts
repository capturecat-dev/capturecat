import { describe, expect, it } from "vitest";

import { adminTools, findModelContext, registerAdminTools, type AdminDeps, type AdminUserRow } from "./webmcp";

const user = (id: string, createdAt: string, storageBytes: number, lastActive: string | null): AdminUserRow => ({
  id,
  email: `${id}@example.com`,
  name: null,
  createdAt,
  tier: "free",
  role: "user",
  providers: ["google"],
  signup: { country: "GB", via: "web", source: { label: "ChatGPT" } },
  usage: { storageBytes, videos: 1, projects: 0, lastActive },
});

const deps = (calls: string[] = []): AdminDeps => ({
  analytics: async (days) => {
    calls.push(`analytics:${days}`);
    return { range: { days } } as never;
  },
  listUsers: async () => ({
    users: [
      user("old", "2026-01-01T00:00:00Z", 900, "2026-10-01T00:00:00Z"),
      user("new", "2026-10-20T00:00:00Z", 10, "2026-10-26T00:00:00Z"),
    ],
  }),
  userActivity: async (userId) => ({ user: { id: userId } }) as never,
});

function fakeContext() {
  const registered: Array<{ name: string; annotations?: object; execute: (i: Record<string, unknown>, o: { signal: AbortSignal }) => Promise<string> }> = [];
  let signal: AbortSignal | undefined;
  return {
    registered,
    get signal() {
      return signal;
    },
    registerTool(tool: (typeof registered)[number], options?: { signal?: AbortSignal }) {
      registered.push(tool);
      signal = options?.signal;
      return Promise.resolve();
    },
  };
}

const run = async (ctx: ReturnType<typeof fakeContext>, name: string, input: Record<string, unknown> = {}) =>
  ctx.registered.find((t) => t.name === name)!.execute(input, { signal: new AbortController().signal });

describe("admin WebMCP", () => {
  it("prefers document.modelContext and falls back to navigator", () => {
    const a = { registerTool() {} };
    const b = { registerTool() {} };
    expect(findModelContext({ document: { modelContext: a }, navigator: { modelContext: b } })).toBe(a);
    expect(findModelContext({ navigator: { modelContext: b } })).toBe(b);
    expect(findModelContext({})).toBeNull();
  });

  it("registers every tool read-only and unregisters through the signal", () => {
    const ctx = fakeContext();
    const off = registerAdminTools(adminTools(deps()), ctx);
    expect(ctx.registered.map((t) => t.name)).toEqual(["get_admin_analytics", "list_admin_users", "get_user_activity"]);
    expect(ctx.registered.every((t) => JSON.stringify(t.annotations) === '{"readOnlyHint":true,"consequentialHint":false}')).toBe(true);
    off();
    expect(ctx.signal?.aborted).toBe(true);
  });

  it("validates the range and defaults to 30 days", async () => {
    const calls: string[] = [];
    const ctx = fakeContext();
    registerAdminTools(adminTools(deps(calls)), ctx);
    await run(ctx, "get_admin_analytics");
    await run(ctx, "get_admin_analytics", { days: 7 });
    expect(calls).toEqual(["analytics:30", "analytics:7"]);
    expect(await run(ctx, "get_admin_analytics", { days: 12 })).toMatch(/^ERROR: `days` must be/);
  });

  it("sorts users like the Users table", async () => {
    const ctx = fakeContext();
    registerAdminTools(adminTools(deps()), ctx);
    const ids = async (sort: string) =>
      (JSON.parse(await run(ctx, "list_admin_users", { sort })) as { users: Array<{ id: string }> }).users.map((u) => u.id);
    expect(await ids("newest")).toEqual(["new", "old"]);
    expect(await ids("storage")).toEqual(["old", "new"]);
    expect(await ids("active")).toEqual(["new", "old"]);
    expect(await run(ctx, "list_admin_users", { sort: "email" })).toMatch(/^ERROR:/);
  });

  it("requires a user id", async () => {
    const ctx = fakeContext();
    registerAdminTools(adminTools(deps()), ctx);
    expect(await run(ctx, "get_user_activity", {})).toBe("ERROR: `userId` is required.");
    expect(JSON.parse(await run(ctx, "get_user_activity", { userId: "u1" }))).toEqual({ user: { id: "u1" } });
  });

  it("is a no-op without WebMCP", () => {
    expect(() => registerAdminTools(adminTools(deps()), null)()).not.toThrow();
  });
});
