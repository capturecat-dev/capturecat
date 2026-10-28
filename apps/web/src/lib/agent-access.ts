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
  "webhooks:write",
  "projects:read",
  "projects:write",
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
  "webhooks:write": { label: "Webhooks", description: "List and add webhook endpoints for your account's events." },
  "projects:read": { label: "Read projects", description: "Your cloud projects: timeline, effects, style and version history." },
  "projects:write": { label: "Edit projects", description: "Zooms, cuts, trims, speed, blur, annotations and style; restore versions. Every edit is a version you can undo." },
};

/** The order and grouping the create form shows. */
export const SCOPE_GROUPS: Array<{ title: string; scopes: AgentScope[] }> = [
  { title: "Videos", scopes: ["videos:read", "videos:write"] },
  { title: "Comments", scopes: ["comments:read", "comments:write"] },
  { title: "Playlists", scopes: ["playlists:read", "playlists:write"] },
  { title: "Projects", scopes: ["projects:read", "projects:write"] },
  { title: "More", scopes: ["analytics:read", "screenshots", "account:read", "webhooks:write"] },
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
  // Cloud-project editing (apps/api/src/mcp/project-tools.ts).
  { name: "list_projects", scope: "projects:read", summary: "Your cloud projects with durations, thumbnails and editor links." },
  { name: "describe_project", scope: "projects:read", summary: "A project's timeline, effects, style, camera and captions, with ids." },
  { name: "style_options", scope: "projects:read", summary: "Every style key with its range and current value." },
  { name: "get_editing_playbook", scope: "projects:read", summary: "How edits work (time, lanes, coordinates, taste) and every edit op's arguments." },
  { name: "apply_edits", scope: "projects:write", summary: "Zoom, tilt, auto-zoom, cut, trim, speed, blur and annotation edits, saved atomically." },
  { name: "set_style", scope: "projects:write", summary: "Background, canvas, cursor, camera and other look settings." },
  { name: "list_versions", scope: "projects:read", summary: "The project's history, with who (person or agent) changed what." },
  { name: "restore_version", scope: "projects:write", summary: "Bring back an earlier version, as a new version." },
  { name: "open_in_editor", scope: "projects:read", summary: "The web editor link to see, play and export the result." },
  // "Ask me first" and webhooks (apps/api/src/mcp/approval-gate.ts, lib/webhooks.ts).
  { name: "get_approval", scope: "videos:write", summary: "Whether you approved, denied or haven't decided an agent's request yet." },
  { name: "list_webhooks", scope: "webhooks:write", summary: "Your webhook endpoints and their delivery health (never their secrets)." },
  { name: "create_webhook", scope: "webhooks:write", summary: "Add an https endpoint for signed events; the secret is returned once." },
];

/** Tools that ask the account owner first (the approval link) — the docs and
 *  the Settings copy say so. */
export const ASK_FIRST_TOOLS = ["post_comment", "update_share_settings"] as const;

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

// ---------------------------------------------------------------------------
// Phase 2: plan gates, "ask me first", OAuth connectors, webhooks
// ---------------------------------------------------------------------------

/** The plan's agent gates (apps/api/src/lib/agent-features.ts). */
export interface AgentFeatures {
  agentAccess: boolean;
  agentWebhooks: boolean;
  agentEditing: boolean;
}

/** What Claude.ai / ChatGPT custom connectors are given: just the URL — they
 *  sign in with CaptureCat (OAuth) themselves. */
export const CONNECTOR_URL = MCP_ENDPOINT;

/** An agent's request waiting for the owner (GET /api/agent-approvals). */
export interface ApprovalDetail {
  id: string;
  tool: string;
  summary: string;
  details: string[];
  videoId: string | null;
  status: "pending" | "approved" | "denied" | "expired" | "used";
  createdAt: string;
  decidedAt: string | null;
  expiresAt: string;
  usedAt: string | null;
  requester: {
    tokenName: string | null;
    tokenPrefix: string | null;
    kind: "personal" | "oauth";
    oauthClient: { clientId: string; name: string; logoUri: string | null; clientUri: string | null } | null;
  };
  video: { id: string; title: string; isPrivate: boolean } | null;
  approveUrl: string;
  videoShareUrl: string | null;
}

/** Who is asking, in one line: the OAuth app's name, else the token's. */
export function requesterName(a: Pick<ApprovalDetail, "requester">): string {
  return a.requester.oauthClient?.name ?? a.requester.tokenName ?? "An agent";
}

/** "Post a comment" / "Change share settings" for a gated tool. */
export function approvalAction(tool: string): string {
  if (tool === "post_comment") return "Post a comment";
  if (tool === "update_share_settings") return "Make a video more visible";
  return tool.replace(/_/g, " ");
}

/** "expires in 12 min" / "expired". */
export function minutesLeft(expiresAt: string, now: Date = new Date()): string {
  const min = Math.ceil((Date.parse(expiresAt) - now.getTime()) / 60_000);
  if (min <= 0) return "expired";
  return `expires in ${min} min`;
}

/** A connected OAuth app (GET /api/oauth/apps). */
export interface ConnectedApp {
  clientId: string;
  name: string;
  kind: "dcr" | "cimd";
  logoUri: string | null;
  clientUri: string | null;
  verifiedHost: string | null;
  scopes: string[];
  connectedAt: string;
  lastUsedAt: string | null;
  connections: number;
}

/** What the consent page shows (GET /api/oauth/authorize/info). */
export interface ConsentInfo {
  client: {
    clientId: string;
    name: string;
    kind: "dcr" | "cimd";
    logoUri: string | null;
    clientUri: string | null;
    verifiedHost: string | null;
    redirectUri: string;
    redirectHost: string;
  };
  scopes: AgentScope[];
  resource: string;
  available: boolean;
  unavailableReason: string | null;
}

/** The authorization request's parameters, as the consent page forwards
 *  them (never trusted: the API re-validates every one). */
export const OAUTH_PARAMS = [
  "response_type",
  "client_id",
  "redirect_uri",
  "scope",
  "state",
  "code_challenge",
  "code_challenge_method",
  "resource",
] as const;

export const WEBHOOK_EVENTS = ["video.ready", "comment.created", "share.viewed", "project.saved", "upload.failed"] as const;
export type WebhookEvent = (typeof WEBHOOK_EVENTS)[number];

export const WEBHOOK_EVENT_LABELS: Record<WebhookEvent, { label: string; description: string }> = {
  "video.ready": { label: "Video ready", description: "A shared video or new version finished uploading." },
  "comment.created": { label: "New comment", description: "Someone commented (their text is marked untrusted)." },
  "share.viewed": { label: "Share viewed", description: "A new viewer — at most once per video per 10 minutes." },
  "project.saved": { label: "Project saved", description: "A cloud project was saved." },
  "upload.failed": { label: "Upload failed", description: "A share upload failed or was refused." },
};

export interface WebhookEndpointSummary {
  id: string;
  url: string;
  description: string | null;
  events: WebhookEvent[];
  active: boolean;
  createdAt: string;
  updatedAt: string;
  createdBy: "settings" | "agent";
  lastSuccessAt: string | null;
  lastFailureAt: string | null;
  failureCount: number;
  disabledReason: string | null;
}

export interface WebhookDelivery {
  id: string;
  event: string;
  status: "pending" | "delivered" | "failed" | "cancelled";
  attempt: number;
  responseCode: number | null;
  error: string | null;
  createdAt: string;
  lastAttemptAt: string | null;
  nextAttemptAt: string | null;
  deliveredAt: string | null;
}

/** Client-side mirror of the API's rule, for instant form feedback only —
 *  the API's SSRF guard (lib/outbound-url.ts) decides. */
export function webhookUrlProblem(raw: string): string | null {
  let url: URL;
  try {
    url = new URL(raw.trim());
  } catch {
    return "Enter a full URL, starting with https://";
  }
  if (url.protocol !== "https:") return "Webhooks are sent over https only";
  const host = url.hostname;
  if (/^\d+\.\d+\.\d+\.\d+$/.test(host) || host.includes(":") || host.startsWith("[")) return "Use a domain name, not an IP address";
  if (!host.includes(".") || host === "localhost" || host.endsWith(".local") || host.endsWith(".localhost")) {
    return "The endpoint must be on the public internet";
  }
  return null;
}
