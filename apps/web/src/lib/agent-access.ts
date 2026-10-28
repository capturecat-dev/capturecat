/**
 * Agent access: the scoped tokens cloud agents use with CaptureCat's remote
 * MCP server (https://mcp.capturecat.so/mcp). The API owns the tokens
 * (apps/api/src/lib/agent-tokens.ts, routes/agent-tokens.ts); this module
 * holds what the Settings section, the docs and the discovery files say
 * about them, so the copy-paste snippets are written in exactly one place.
 *
 * AGENT_SCOPES mirrors the API's list — agent-access.test.ts reads the API
 * source and fails when the two drift.
 */

export const MCP_ENDPOINT = "https://mcp.capturecat.so/mcp";

export const AGENT_SCOPES = [
  "videos:read",
  "videos:write",
  "comments:read",
  "comments:write",
  "analytics:read",
  "playlists:read",
  "playlists:write",
  "screenshots",
  "account:read",
] as const;
export type AgentScope = (typeof AGENT_SCOPES)[number];

export const SCOPE_INFO: Record<AgentScope, { label: string; description: string }> = {
  "account:read": { label: "Account", description: "Plan, features, limits and storage used." },
  "videos:read": { label: "Read videos", description: "List videos, details, transcripts, AI summaries, transcript search." },
  "videos:write": { label: "Share settings", description: "Privacy, password, expiry, view cap, download, call-to-action." },
  "comments:read": { label: "Read comments", description: "Comment threads and drawings on your videos." },
  "comments:write": { label: "Post comments", description: "Comment and reply as you, marked “(via agent)”." },
  "analytics:read": { label: "Analytics", description: "Views, watch time, drop-off, countries, referrers." },
  "playlists:read": { label: "Read playlists", description: "Your playlists and what is in them." },
  "playlists:write": { label: "Add to playlists", description: "Add your videos to your playlists." },
  screenshots: { label: "Screenshots", description: "Render web pages to images; uses your monthly quota." },
};

/** The order and grouping the create form shows. */
export const SCOPE_GROUPS: Array<{ title: string; scopes: AgentScope[] }> = [
  { title: "Videos", scopes: ["videos:read", "videos:write"] },
  { title: "Comments", scopes: ["comments:read", "comments:write"] },
  { title: "Playlists", scopes: ["playlists:read", "playlists:write"] },
  { title: "More", scopes: ["analytics:read", "screenshots", "account:read"] },
];

/** Read-only by default: a new token can look but not change anything. */
export const DEFAULT_SCOPES: AgentScope[] = [
  "account:read",
  "videos:read",
  "comments:read",
  "analytics:read",
  "playlists:read",
];

export const EXPIRY_OPTIONS: Array<{ days: number | null; label: string }> = [
  { days: 30, label: "30 days" },
  { days: 90, label: "90 days" },
  { days: 365, label: "1 year" },
  { days: null, label: "Never" },
];

/**
 * The remote server's tools, for the docs, the skill and the server card.
 * Mirrors apps/api/src/mcp/tools.ts (names, order, scopes) — the test reads
 * that file and fails on drift. Descriptions here are the short public ones;
 * the server's own (tools/list) are longer.
 */
export const MCP_TOOLS: Array<{ name: string; scope: AgentScope; summary: string }> = [
  { name: "get_account", scope: "account:read", summary: "Plan, features, limits, storage and screenshot usage." },
  { name: "list_videos", scope: "videos:read", summary: "Your shared videos with share URLs, privacy, duration and views, paged." },
  { name: "get_video", scope: "videos:read", summary: "One video's details and share-page settings." },
  { name: "get_transcript", scope: "videos:read", summary: "The timestamped transcript." },
  { name: "get_summary", scope: "videos:read", summary: "The AI title, summary and chapters, when one exists." },
  { name: "search_transcripts", scope: "videos:read", summary: "Which videos mention a phrase, with timestamps." },
  { name: "list_comments", scope: "comments:read", summary: "Comment threads and drawings on a video." },
  { name: "post_comment", scope: "comments:write", summary: "Comment or reply as you, marked “(via agent)”." },
  { name: "update_share_settings", scope: "videos:write", summary: "Privacy, password, expiry, view cap, download, call-to-action." },
  { name: "get_video_analytics", scope: "analytics:read", summary: "Views, watch time, drop-off, countries and referrers." },
  { name: "list_playlists", scope: "playlists:read", summary: "Your playlists and their videos." },
  { name: "add_to_playlist", scope: "playlists:write", summary: "Add a video to a playlist." },
  { name: "take_screenshot", scope: "screenshots", summary: "Render a web page to an image (monthly quota)." },
];

export function isWriteScope(scope: AgentScope): boolean {
  return scope.endsWith(":write") || scope === "screenshots";
}

/** Ready to paste into a terminal (Claude Code). */
export function claudeMcpAddCommand(token: string): string {
  return `claude mcp add --transport http capturecat ${MCP_ENDPOINT} --header "Authorization: Bearer ${token}"`;
}

/** The generic `mcpServers` entry most clients (Claude Desktop, Cursor,
 *  Windsurf, …) accept for a remote HTTP server. */
export function mcpJsonConfig(token: string): string {
  return JSON.stringify(
    {
      mcpServers: {
        capturecat: {
          type: "http",
          url: MCP_ENDPOINT,
          headers: { Authorization: `Bearer ${token}` },
        },
      },
    },
    null,
    2,
  );
}

export interface AgentTokenSummary {
  id: string;
  name: string;
  prefix: string;
  scopes: string[];
  createdAt: string;
  expiresAt: string | null;
  lastUsedAt: string | null;
  revokedAt: string | null;
}

export type TokenStatus = "active" | "expired" | "revoked";

export function tokenStatus(t: Pick<AgentTokenSummary, "expiresAt" | "revokedAt">, now: Date = new Date()): TokenStatus {
  if (t.revokedAt) return "revoked";
  if (t.expiresAt && Date.parse(t.expiresAt) <= now.getTime()) return "expired";
  return "active";
}

/** Active tokens first (newest first), then expired and revoked ones. */
export function sortTokens<T extends AgentTokenSummary>(tokens: T[], now: Date = new Date()): T[] {
  const rank = (t: T) => (tokenStatus(t, now) === "active" ? 0 : 1);
  return [...tokens].sort((a, b) => rank(a) - rank(b) || b.createdAt.localeCompare(a.createdAt));
}

/** "just now", "5 min ago", "3 h ago", "12 days ago", else a date. */
export function relativeTime(iso: string, now: Date = new Date()): string {
  const diff = now.getTime() - Date.parse(iso);
  if (!Number.isFinite(diff)) return "";
  const min = Math.round(diff / 60_000);
  if (min < 1) return "just now";
  if (min < 60) return `${min} min ago`;
  const h = Math.round(min / 60);
  if (h < 24) return `${h} h ago`;
  const d = Math.round(h / 24);
  if (d <= 30) return `${d} day${d === 1 ? "" : "s"} ago`;
  return new Date(iso).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
}

/** "expires in 12 days", "expired 3 days ago", "never expires". */
export function describeExpiry(expiresAt: string | null, now: Date = new Date()): string {
  if (!expiresAt) return "never expires";
  const days = Math.round((Date.parse(expiresAt) - now.getTime()) / 86_400_000);
  if (days < 0) return `expired ${-days} day${days === -1 ? "" : "s"} ago`;
  if (days === 0) return "expires today";
  return `expires in ${days} day${days === 1 ? "" : "s"}`;
}
