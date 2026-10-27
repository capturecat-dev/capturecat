/**
 * WebMCP outside the editor: tools every surface of the site registers on
 * page load, so a browser agent can search and read the site, get pricing
 * and the download, read a shared video, and — signed in — work with the
 * user's own videos.
 *
 * The editor (src/editor/webmcp/register.ts) keeps its own catalog, generated
 * from the Mac app's MCP server; this module reuses its detection
 * (`document.modelContext`, falling back to the deprecated
 * `navigator.modelContext`) and its result contract (JSON for data, an
 * actionable `ERROR:` line on failure). Tool names here never collide with
 * the editor's.
 *
 * Every tool's data access is injected (`SiteDeps` / `DashboardDeps`), so the
 * definitions are unit-tested without a browser.
 */
import { findModelContext, type ModelContextLike, type ToolArgs } from "@/editor/webmcp/register";

export interface PageTool {
  name: string;
  title: string;
  description: string;
  inputSchema: { type: "object"; properties: Record<string, unknown>; required: string[]; additionalProperties?: boolean };
  /** No side effects at all. */
  readOnly: boolean;
  /** Changes something the user would want to confirm (WebMCP consequentialHint). */
  consequential?: boolean;
  execute: (input: ToolArgs, signal: AbortSignal) => Promise<unknown>;
}

/** Register tools; returns an unregister function. No-op without WebMCP. */
export function registerPageTools(tools: PageTool[], context: ModelContextLike | null = findModelContext()): () => void {
  if (!context || tools.length === 0) return () => {};
  const controller = new AbortController();
  for (const tool of tools) {
    void Promise.resolve(
      context.registerTool(
        {
          name: tool.name,
          title: tool.title,
          description: tool.description,
          inputSchema: tool.inputSchema,
          annotations: { readOnlyHint: tool.readOnly, consequentialHint: tool.consequential === true },
          execute: async (input, { signal }) => {
            try {
              const result = await tool.execute(input ?? {}, signal);
              return typeof result === "string" ? result : JSON.stringify(result ?? null);
            } catch (error) {
              return `ERROR: ${error instanceof Error ? error.message : String(error)}`;
            }
          },
        },
        { signal: controller.signal },
      ),
    ).catch(() => {
      // A duplicate name (another surface already registered it) must not
      // break the page; that tool simply stays with its first owner.
    });
  }
  return () => controller.abort();
}

// ---------------------------------------------------------------- site tools

export interface SiteDeps {
  siteUrl: string;
  apiUrl: string;
  fetchText: (url: string, signal: AbortSignal) => Promise<{ ok: boolean; status: number; text: string }>;
  navigate: (path: string) => void;
}

const MAX_PAGE_CHARS = 40_000;
const SAFE_PATH = /^\/[A-Za-z0-9/_\-.]*$/;

function str(input: ToolArgs, key: string): string {
  const v = input[key];
  if (typeof v !== "string" || !v.trim()) throw new Error(`\`${key}\` is required and must be a non-empty string.`);
  return v.trim();
}

function sitePath(raw: string): string {
  let path = raw;
  // Accept a full capturecat.so URL too.
  if (/^https?:\/\//.test(path)) path = new URL(path).pathname;
  if (!SAFE_PATH.test(path) || path.includes("..") || path.startsWith("//")) {
    throw new Error(`\`${raw}\` is not a path on this site. Use one like "/pricing" or "/docs".`);
  }
  return path;
}

/** "/" → "/index.md", "/pricing" → "/pricing.md" (the site's Markdown twins). */
export function markdownPathFor(path: string): string {
  if (path.endsWith(".md")) return path;
  const trimmed = path.length > 1 ? path.replace(/\/+$/, "") : path;
  return trimmed === "/" ? "/index.md" : `${trimmed}.md`;
}

export interface SiteSearchHit {
  title: string;
  url: string;
  markdownUrl: string;
  description: string;
}

/** Rank llms.txt link lines against a query: title words count triple. */
export function searchLlmsTxt(llms: string, query: string, limit: number): SiteSearchHit[] {
  const terms = query.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length >= 2);
  if (terms.length === 0) return [];
  const hits: Array<SiteSearchHit & { score: number }> = [];
  for (const line of llms.split("\n")) {
    const m = line.match(/^- \[(.+?)\]\((\S+?)\)(?::\s*(.*))?$/);
    if (!m) continue;
    const [, title, markdownUrl, description = ""] = m;
    const t = title!.toLowerCase();
    const d = description.toLowerCase();
    const score = terms.reduce((s, term) => s + (t.includes(term) ? 3 : 0) + (d.includes(term) ? 1 : 0), 0);
    if (score === 0) continue;
    const url = markdownUrl!.replace(/\/index\.md$/, "/").replace(/\.md$/, "");
    hits.push({ title: title!, url, markdownUrl: markdownUrl!, description, score });
  }
  return hits
    .sort((a, b) => b.score - a.score)
    .slice(0, limit)
    .map(({ score: _score, ...hit }) => hit);
}

export function siteTools(deps: SiteDeps): PageTool[] {
  return [
    {
      name: "search_capturecat_site",
      title: "Search capturecat.so",
      description:
        "Search CaptureCat's public pages (product, pricing, docs, guides, comparisons) by keywords. Returns titles, " +
        "page URLs and Markdown URLs; read one with read_capturecat_page. Use this before answering a question about " +
        "what CaptureCat does or how to use it.",
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", minLength: 2, description: 'Keywords, e.g. "auto zoom", "custom domain", "vs Loom".' },
          limit: { type: "integer", minimum: 1, maximum: 20, default: 8, description: "Maximum results." },
        },
        required: ["query"],
        additionalProperties: false,
      },
      readOnly: true,
      execute: async (input, signal) => {
        const query = str(input, "query");
        const limit = Math.min(20, Math.max(1, Number(input.limit) || 8));
        const res = await deps.fetchText(`${deps.siteUrl}/llms.txt`, signal);
        if (!res.ok) throw new Error(`The site index is unavailable (HTTP ${res.status}). Try again shortly.`);
        const results = searchLlmsTxt(res.text, query, limit);
        return { query, results, note: results.length ? undefined : "No page matched; try fewer or different words." };
      },
    },
    {
      name: "read_capturecat_page",
      title: "Read a capturecat.so page",
      description:
        "Read any public capturecat.so page as Markdown (the same content as the HTML page). Pass a path like " +
        '"/pricing", "/docs/getting-started" or "/" for the home page.',
      inputSchema: {
        type: "object",
        properties: { path: { type: "string", description: 'Site path, e.g. "/pricing". A full capturecat.so URL also works.' } },
        required: ["path"],
        additionalProperties: false,
      },
      readOnly: true,
      execute: async (input, signal) => {
        const path = sitePath(str(input, "path"));
        const res = await deps.fetchText(`${deps.siteUrl}${markdownPathFor(path)}`, signal);
        if (!res.ok) throw new Error(`No page at ${path} (HTTP ${res.status}). Use search_capturecat_site to find one.`);
        return res.text.length > MAX_PAGE_CHARS ? `${res.text.slice(0, MAX_PAGE_CHARS)}\n\n[truncated]` : res.text;
      },
    },
    {
      name: "get_capturecat_pricing",
      title: "CaptureCat pricing",
      description:
        "Get CaptureCat's current plan and prices as JSON, live from the same source the pricing page uses " +
        "(prices come from Stripe). Recording, editing and export are free; the paid plan adds sharing features.",
      inputSchema: { type: "object", properties: {}, required: [], additionalProperties: false },
      readOnly: true,
      execute: async (_input, signal) => {
        const res = await deps.fetchText(`${deps.apiUrl}/api/plans`, signal);
        if (!res.ok) throw new Error(`Pricing is unavailable (HTTP ${res.status}). See ${deps.siteUrl}/pricing.`);
        return { pricingPage: `${deps.siteUrl}/pricing`, plans: JSON.parse(res.text) as unknown };
      },
    },
    {
      name: "get_capturecat_download",
      title: "Download CaptureCat for Mac",
      description:
        "Get the latest CaptureCat for Mac release (version, date, minimum macOS) and its direct download links for " +
        "Apple silicon and Intel. Give the user the link for their Mac; there is no installer for other systems " +
        "(they can use the browser app at https://app.capturecat.so).",
      inputSchema: { type: "object", properties: {}, required: [], additionalProperties: false },
      readOnly: true,
      execute: async (_input, signal) => {
        const res = await deps.fetchText(`${deps.apiUrl}/api/releases/latest`, signal);
        if (!res.ok) throw new Error(`The release feed is unavailable (HTTP ${res.status}). See ${deps.siteUrl}/download.`);
        const latest = JSON.parse(res.text) as { version?: string; date?: string; minOS?: string };
        return {
          version: latest.version ?? null,
          date: latest.date ?? null,
          minimumMacOS: latest.minOS ?? null,
          downloads: {
            appleSilicon: `${deps.apiUrl}/api/releases/download/arm64`,
            intel: `${deps.apiUrl}/api/releases/download/x86_64`,
          },
          page: `${deps.siteUrl}/download`,
        };
      },
    },
    {
      name: "open_capturecat_page",
      title: "Open a capturecat.so page",
      description: 'Navigate this tab to a capturecat.so page, e.g. "/pricing" or "/download", so the user sees it.',
      inputSchema: {
        type: "object",
        properties: { path: { type: "string", description: 'Site path, e.g. "/download".' } },
        required: ["path"],
        additionalProperties: false,
      },
      readOnly: false,
      execute: async (input) => {
        const path = sitePath(str(input, "path"));
        deps.navigate(path);
        return `Opened ${path}`;
      },
    },
  ];
}

/** On a /share/<id> page: the video's title, summary and transcript. */
export function shareTools(deps: SiteDeps, videoId: string): PageTool[] {
  return [
    {
      name: "read_shared_video",
      title: "Read this shared video",
      description:
        "Read the CaptureCat video shared on this page as Markdown: title, AI summary and chapters when present, " +
        "and the timestamped transcript. Use it to summarise or answer questions about the video.",
      inputSchema: { type: "object", properties: {}, required: [], additionalProperties: false },
      readOnly: true,
      execute: async (_input, signal) => {
        const res = await deps.fetchText(`/share/${encodeURIComponent(videoId)}.md`, signal);
        if (!res.ok) throw new Error(`This video's text is unavailable (HTTP ${res.status}).`);
        return res.text.length > MAX_PAGE_CHARS ? `${res.text.slice(0, MAX_PAGE_CHARS)}\n\n[truncated]` : res.text;
      },
    },
  ];
}

// ----------------------------------------------------------- dashboard tools

export interface DashboardVideo {
  videoId: string;
  fileName: string;
  durationSeconds: number;
  fileSizeBytes: number;
  isPrivate: boolean;
  createdAt: string;
  url: string;
  hasPassword: boolean;
  commentsEnabled: boolean;
}

export interface DashboardDeps {
  listVideos: () => Promise<{ videos: DashboardVideo[]; storageUsedBytes: number; storageLimitBytes: number }>;
  searchTranscripts: (q: string) => Promise<{ results: Array<{ videoId: string; segments: Array<{ start: number; end: number; text: string }> }> }>;
  videoAnalytics: (videoId: string) => Promise<{
    views: number;
    plays: number;
    completions: number;
    avgWatchedSeconds: number;
    durationSeconds: number;
    countries: Array<{ country: string; count: number }>;
    referrers: Array<{ referrer: string; count: number }>;
    comments: Array<{ authorName: string; body: string; videoTime: number; createdAt: string }>;
  }>;
  account: () => Promise<{ email: string; tier: string }>;
  setPrivacy: (videoId: string, isPrivate: boolean) => Promise<unknown>;
  navigate: (path: string) => void;
}

export const DASHBOARD_PAGES = ["videos", "projects", "record", "settings", "billing", "team"] as const;

export function dashboardTools(deps: DashboardDeps): PageTool[] {
  return [
    {
      name: "list_my_videos",
      title: "List my shared videos",
      description:
        "List the signed-in user's CaptureCat share-link videos (newest first) with id, file name, duration, " +
        "privacy, share URL and storage used. Use the id with get_video_analytics or set_video_privacy.",
      inputSchema: {
        type: "object",
        properties: { limit: { type: "integer", minimum: 1, maximum: 200, default: 50, description: "Maximum videos." } },
        required: [],
        additionalProperties: false,
      },
      readOnly: true,
      execute: async (input) => {
        const limit = Math.min(200, Math.max(1, Number(input.limit) || 50));
        const { videos, storageUsedBytes, storageLimitBytes } = await deps.listVideos();
        return {
          storageUsedBytes,
          storageLimitBytes,
          total: videos.length,
          videos: videos.slice(0, limit).map((v) => ({
            videoId: v.videoId,
            fileName: v.fileName,
            durationSeconds: v.durationSeconds,
            sizeBytes: v.fileSizeBytes,
            private: v.isPrivate,
            passwordProtected: v.hasPassword,
            commentsEnabled: v.commentsEnabled,
            createdAt: v.createdAt,
            shareUrl: v.url,
          })),
        };
      },
    },
    {
      name: "search_my_transcripts",
      title: "Search my video transcripts",
      description:
        "Find the moments in the signed-in user's shared videos where something was said. Returns matching " +
        "transcript segments with start/end seconds per video.",
      inputSchema: {
        type: "object",
        properties: { query: { type: "string", minLength: 2, description: "Words to look for in what was said." } },
        required: ["query"],
        additionalProperties: false,
      },
      readOnly: true,
      execute: async (input) => deps.searchTranscripts(str(input, "query")),
    },
    {
      name: "get_video_analytics",
      title: "Viewer analytics for one video",
      description:
        "Viewer analytics for one of the signed-in user's videos: views, plays, completions, average watch time, " +
        "top countries and referrers, and comments with their timestamps.",
      inputSchema: {
        type: "object",
        properties: { videoId: { type: "string", description: "A videoId from list_my_videos." } },
        required: ["videoId"],
        additionalProperties: false,
      },
      readOnly: true,
      execute: async (input) => {
        const a = await deps.videoAnalytics(str(input, "videoId"));
        return {
          views: a.views,
          plays: a.plays,
          completions: a.completions,
          avgWatchedSeconds: a.avgWatchedSeconds,
          durationSeconds: a.durationSeconds,
          countries: a.countries.slice(0, 10),
          referrers: a.referrers.slice(0, 10),
          comments: a.comments.map((c) => ({ author: c.authorName, at: c.videoTime, text: c.body, createdAt: c.createdAt })),
        };
      },
    },
    {
      name: "get_my_account",
      title: "My CaptureCat account",
      description: "The signed-in user's email and plan tier (free, tester or paid).",
      inputSchema: { type: "object", properties: {}, required: [], additionalProperties: false },
      readOnly: true,
      execute: async () => {
        const me = await deps.account();
        return { email: me.email, tier: me.tier };
      },
    },
    {
      name: "set_video_privacy",
      title: "Make a video public or private",
      description:
        "Make one of the signed-in user's videos private (only they can watch) or public (anyone with the link). " +
        "Confirm with the user first: a public video is viewable by anyone who has its link.",
      inputSchema: {
        type: "object",
        properties: {
          videoId: { type: "string", description: "A videoId from list_my_videos." },
          private: { type: "boolean", description: "true = private, false = anyone with the link." },
        },
        required: ["videoId", "private"],
        additionalProperties: false,
      },
      readOnly: false,
      consequential: true,
      execute: async (input) => {
        const videoId = str(input, "videoId");
        if (typeof input.private !== "boolean") throw new Error("`private` must be true or false.");
        await deps.setPrivacy(videoId, input.private);
        return { videoId, private: input.private };
      },
    },
    {
      name: "open_dashboard_page",
      title: "Open a dashboard page",
      description: "Navigate the dashboard to one of its pages so the user sees it.",
      inputSchema: {
        type: "object",
        properties: { page: { type: "string", enum: [...DASHBOARD_PAGES], description: "Which dashboard page." } },
        required: ["page"],
        additionalProperties: false,
      },
      readOnly: false,
      execute: async (input) => {
        const page = str(input, "page");
        if (!(DASHBOARD_PAGES as readonly string[]).includes(page)) {
          throw new Error(`\`page\` must be one of ${DASHBOARD_PAGES.join(", ")}.`);
        }
        const path = page === "videos" ? "/app" : `/app/${page}`;
        deps.navigate(path);
        return `Opened ${page}`;
      },
    },
  ];
}
