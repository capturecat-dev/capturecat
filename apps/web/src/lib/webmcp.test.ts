import { describe, expect, it } from "vitest";

import {
  dashboardTools,
  markdownPathFor,
  registerPageTools,
  searchLlmsTxt,
  shareTools,
  siteTools,
  type DashboardDeps,
  type SiteDeps,
} from "./webmcp";

const LLMS = [
  "# CaptureCat",
  "",
  "## Pages",
  "- [Pricing](https://capturecat.so/pricing.md): Free to record, edit, and export. Pro adds share links.",
  "- [Auto zoom](https://capturecat.so/docs/auto-zoom.md): How CaptureCat zooms where you click.",
  "- [Home](https://capturecat.so/index.md): The Mac screen recorder that edits itself.",
  "- not a link line",
].join("\n");

function siteDeps(over: Partial<SiteDeps> = {}): SiteDeps & { fetched: string[]; navigated: string[] } {
  const fetched: string[] = [];
  const navigated: string[] = [];
  return {
    fetched,
    navigated,
    siteUrl: "https://capturecat.so",
    apiUrl: "https://api.capturecat.so",
    fetchText: async (url) => {
      fetched.push(url);
      if (url.endsWith("/llms.txt")) return { ok: true, status: 200, text: LLMS };
      if (url.endsWith("/api/releases/latest")) return { ok: true, status: 200, text: '{"version":"1.2.0","date":"2026-10-07","minOS":"14.0"}' };
      if (url.endsWith("/nope.md")) return { ok: false, status: 404, text: "" };
      return { ok: true, status: 200, text: `# page ${url}` };
    },
    navigate: (path) => void navigated.push(path),
    ...over,
  };
}

function fakeContext() {
  const tools: Array<{ name: string; annotations?: { readOnlyHint?: boolean; consequentialHint?: boolean }; execute: (i: Record<string, unknown>, o: { signal: AbortSignal }) => Promise<string> }> = [];
  let signal: AbortSignal | undefined;
  return {
    tools,
    get signal() {
      return signal;
    },
    registerTool(tool: (typeof tools)[number], options?: { signal?: AbortSignal }) {
      tools.push(tool);
      signal = options?.signal;
      return Promise.resolve();
    },
  };
}

const call = (ctx: ReturnType<typeof fakeContext>, name: string, input: Record<string, unknown> = {}) =>
  ctx.tools.find((t) => t.name === name)!.execute(input, { signal: new AbortController().signal });

describe("searchLlmsTxt", () => {
  it("ranks title matches above description matches and maps .md links to pages", () => {
    // "Auto zoom" matches in title and description (4) and beats "Pricing" (title only, 3).
    const hits = searchLlmsTxt(LLMS, "zoom pricing", 5);
    expect(hits.map((h) => h.title)).toEqual(["Auto zoom", "Pricing"]);
    expect(hits[1]).toMatchObject({ url: "https://capturecat.so/pricing", markdownUrl: "https://capturecat.so/pricing.md" });
    // A description-only match still counts, below any title match.
    expect(searchLlmsTxt(LLMS, "share", 5).map((h) => h.title)).toEqual(["Pricing"]);
    expect(searchLlmsTxt(LLMS, "edits itself", 5)[0]!.url).toBe("https://capturecat.so/");
  });

  it("ignores one-letter noise and respects the limit", () => {
    expect(searchLlmsTxt(LLMS, "a", 5)).toEqual([]);
    expect(searchLlmsTxt(LLMS, "capturecat", 1)).toHaveLength(1);
  });
});

describe("markdownPathFor", () => {
  it("maps paths to the site's Markdown twins", () => {
    expect(markdownPathFor("/")).toBe("/index.md");
    expect(markdownPathFor("/pricing")).toBe("/pricing.md");
    expect(markdownPathFor("/docs/api/")).toBe("/docs/api.md");
    expect(markdownPathFor("/agents.md")).toBe("/agents.md");
  });
});

describe("site tools", () => {
  it("registers with the right annotations and unregisters on abort", () => {
    const ctx = fakeContext();
    const off = registerPageTools(siteTools(siteDeps()), ctx);
    expect(ctx.tools.map((t) => t.name)).toEqual([
      "search_capturecat_site",
      "read_capturecat_page",
      "get_capturecat_pricing",
      "get_capturecat_download",
      "open_capturecat_page",
    ]);
    expect(ctx.tools.filter((t) => t.annotations?.readOnlyHint).map((t) => t.name)).not.toContain("open_capturecat_page");
    off();
    expect(ctx.signal?.aborted).toBe(true);
  });

  it("searches, reads and refuses paths off the site", async () => {
    const deps = siteDeps();
    const ctx = fakeContext();
    registerPageTools(siteTools(deps), ctx);
    expect(JSON.parse(await call(ctx, "search_capturecat_site", { query: "pricing" })).results[0].title).toBe("Pricing");
    expect(await call(ctx, "read_capturecat_page", { path: "https://capturecat.so/pricing" })).toBe("# page https://capturecat.so/pricing.md");
    expect(await call(ctx, "read_capturecat_page", { path: "/nope" })).toMatch(/^ERROR: No page at \/nope \(HTTP 404\)/);
    expect(await call(ctx, "read_capturecat_page", { path: "//evil.example/x" })).toMatch(/^ERROR: .* is not a path on this site/);
    expect(await call(ctx, "read_capturecat_page", { path: "/../etc" })).toMatch(/^ERROR:/);
    expect(await call(ctx, "search_capturecat_site", {})).toBe("ERROR: `query` is required and must be a non-empty string.");
  });

  it("returns the download links from the release feed", async () => {
    const ctx = fakeContext();
    registerPageTools(siteTools(siteDeps()), ctx);
    expect(JSON.parse(await call(ctx, "get_capturecat_download"))).toEqual({
      version: "1.2.0",
      date: "2026-10-07",
      minimumMacOS: "14.0",
      downloads: {
        appleSilicon: "https://api.capturecat.so/api/releases/download/arm64",
        intel: "https://api.capturecat.so/api/releases/download/x86_64",
      },
      page: "https://capturecat.so/download",
    });
  });

  it("navigates only to site paths", async () => {
    const deps = siteDeps();
    const ctx = fakeContext();
    registerPageTools(siteTools(deps), ctx);
    expect(await call(ctx, "open_capturecat_page", { path: "/download" })).toBe("Opened /download");
    expect(await call(ctx, "open_capturecat_page", { path: "javascript:alert(1)" })).toMatch(/^ERROR:/);
    expect(deps.navigated).toEqual(["/download"]);
  });

  it("reads the shared video's Markdown twin", async () => {
    const deps = siteDeps();
    const ctx = fakeContext();
    registerPageTools(shareTools(deps, "abc123"), ctx);
    await call(ctx, "read_shared_video");
    expect(deps.fetched).toEqual(["/share/abc123.md"]);
  });

  it("is a no-op without WebMCP and survives a rejected registration", async () => {
    expect(() => registerPageTools(siteTools(siteDeps()), null)()).not.toThrow();
    const rejecting = { registerTool: () => Promise.reject(new Error("duplicate")) };
    expect(() => registerPageTools(siteTools(siteDeps()), rejecting)).not.toThrow();
    await new Promise((r) => setTimeout(r, 0));
  });
});

describe("dashboard tools", () => {
  const deps = (log: string[]): DashboardDeps => ({
    listVideos: async () => ({
      storageUsedBytes: 10,
      storageLimitBytes: 100,
      videos: [
        { videoId: "v1", fileName: "demo.mp4", durationSeconds: 12, fileSizeBytes: 9, isPrivate: false, createdAt: "2026-10-27", url: "https://capturecat.so/share/v1", hasPassword: false, commentsEnabled: true },
        { videoId: "v2", fileName: "bug.mp4", durationSeconds: 3, fileSizeBytes: 1, isPrivate: true, createdAt: "2026-10-26", url: "https://capturecat.so/share/v2", hasPassword: true, commentsEnabled: false },
      ],
    }),
    searchTranscripts: async (q) => ({ results: [{ videoId: "v1", segments: [{ start: 1, end: 2, text: q }] }] }),
    videoAnalytics: async () => ({
      views: 5, plays: 4, completions: 2, avgWatchedSeconds: 7, durationSeconds: 12,
      countries: [], referrers: [], comments: [{ authorName: "Ana", body: "nice", videoTime: 3, createdAt: "x" }],
    }),
    account: async () => ({ email: "me@example.com", tier: "paid" }),
    setPrivacy: async (videoId, isPrivate) => void log.push(`${videoId}:${isPrivate}`),
    navigate: (path) => void log.push(path),
  });

  it("marks privacy changes consequential and everything else not", () => {
    const ctx = fakeContext();
    registerPageTools(dashboardTools(deps([])), ctx);
    const flagged = ctx.tools.filter((t) => t.annotations?.consequentialHint).map((t) => t.name);
    expect(flagged).toEqual(["set_video_privacy"]);
  });

  it("maps videos, analytics and account to plain JSON", async () => {
    const ctx = fakeContext();
    registerPageTools(dashboardTools(deps([])), ctx);
    const list = JSON.parse(await call(ctx, "list_my_videos", { limit: 1 }));
    expect(list).toMatchObject({ total: 2, storageUsedBytes: 10, videos: [{ videoId: "v1", private: false, shareUrl: "https://capturecat.so/share/v1" }] });
    expect(JSON.parse(await call(ctx, "get_video_analytics", { videoId: "v1" })).comments).toEqual([
      { author: "Ana", at: 3, text: "nice", createdAt: "x" },
    ]);
    expect(JSON.parse(await call(ctx, "get_my_account"))).toEqual({ email: "me@example.com", tier: "paid" });
  });

  it("validates writes and navigation", async () => {
    const log: string[] = [];
    const ctx = fakeContext();
    registerPageTools(dashboardTools(deps(log)), ctx);
    expect(await call(ctx, "set_video_privacy", { videoId: "v1", private: "yes" })).toMatch(/^ERROR: `private` must be/);
    await call(ctx, "set_video_privacy", { videoId: "v1", private: true });
    await call(ctx, "open_dashboard_page", { page: "billing" });
    await call(ctx, "open_dashboard_page", { page: "videos" });
    expect(await call(ctx, "open_dashboard_page", { page: "admin" })).toMatch(/^ERROR:/);
    expect(log).toEqual(["v1:true", "/app/billing", "/app"]);
  });
});
