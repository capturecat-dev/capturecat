/**
 * DEV-ONLY: canned data for the dashboard lab (/editor-lab/dashboard). The
 * lab renders the real dashboard pages with no session, so every request
 * they make — tRPC (superjson over the batch link), Better Auth's
 * organization endpoints, the API's REST routes, the dev server's local
 * project listing — is answered here by a fetch wrapper, and NOTHING reaches
 * a server. Deterministic on purpose: screenshots compare across runs.
 *
 *   state=full     a working account (default)
 *   state=empty    a brand-new account: no videos, projects, team, domains
 *   state=loading  every request hangs, so pages show their skeletons
 *   tier=free|paid billing tier (default paid)
 *   team=owner|none  team page as an owner, or with no team yet
 *   uploads=0      no in-flight desktop upload in the library
 *   cloud=network  a project's own cloud routes (/api/cloud-projects/<id>…:
 *                  stage, finalize, save) go to the network, where a harness
 *                  answers them — the recorder gate publishes real takes
 */
import superjson from "superjson";

export interface LabOptions {
  state: "full" | "empty" | "loading";
  tier: "free" | "paid";
  team: "owner" | "none";
  uploads: boolean;
  /** Pass /api/cloud-projects/<id>… through to the network (a harness mocks it). */
  cloudNetwork: boolean;
}

// Fixed "now" so relative dates and sort orders never drift between runs.
const NOW = Date.parse("2026-09-30T15:00:00Z");
const ago = (hours: number) => new Date(NOW - hours * 3600_000).toISOString();

/** A recording still: the product's gradient wallpaper with a light app
 *  card on it, as an SVG data URI (no network, no binary fixtures). */
export function labPoster(i: number): string {
  const walls = [
    ["#bf5af2", "#7d5cf0", "#0a84ff"],
    ["#1f3b8f", "#7a3d8a", "#ff9f5a"],
    ["#0f766e", "#0e7490", "#38bdf8"],
    ["#3a2d7a", "#d8687a", "#ffb86b"],
    ["#1c1c1e", "#2c2c2e", "#3a3a3c"],
    ["#4338ca", "#7c3aed", "#db2777"],
  ];
  const [a, b, c] = walls[i % walls.length];
  const accent = ["#0a84ff", "#ff9f0a", "#30d158", "#bf5af2", "#ff375f", "#64d2ff"][i % 6];
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 180">
<defs><linearGradient id="w" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset=".5" stop-color="${b}"/><stop offset="1" stop-color="${c}"/></linearGradient></defs>
<rect width="320" height="180" fill="url(#w)"/>
<rect x="37" y="14" width="246" height="152" rx="7" fill="#000" opacity=".28"/>
<rect x="37" y="12" width="246" height="152" rx="7" fill="#fff"/>
<rect x="37" y="12" width="246" height="12" rx="7" fill="#f2f2f5"/>
<circle cx="45" cy="18" r="2" fill="#ff5f57"/><circle cx="52" cy="18" r="2" fill="#febc2e"/><circle cx="59" cy="18" r="2" fill="#28c840"/>
<rect x="37" y="24" width="52" height="140" fill="#f6f6f8"/>
<rect x="44" y="32" width="30" height="4" rx="2" fill="#c7c7cc"/><rect x="44" y="42" width="36" height="6" rx="3" fill="${accent}" opacity=".85"/>
<rect x="44" y="54" width="26" height="4" rx="2" fill="#d1d1d6"/><rect x="44" y="64" width="32" height="4" rx="2" fill="#d1d1d6"/>
<rect x="100" y="34" width="${70 + (i % 3) * 18}" height="8" rx="3" fill="#1d1d1f"/>
<rect x="100" y="48" width="120" height="4" rx="2" fill="#aeaeb2"/>
<rect x="100" y="64" width="${170 - (i % 4) * 12}" height="${46 + (i % 2) * 14}" rx="5" fill="${accent}" opacity=".14"/>
<rect x="100" y="${118 + (i % 2) * 8}" width="64" height="12" rx="6" fill="${accent}"/>
<path d="M${200 + (i % 3) * 20} ${92 + (i % 2) * 10}v15l4-3.6 2.5 6 2.6-1.1-2.5-5.8h5.3z" fill="#111" stroke="#fff" stroke-width="1.1"/>
</svg>`;
  return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`;
}

const VIDEO_NAMES = [
  "Onboarding tour",
  "Release notes 1.1",
  "Billing walkthrough",
  "Bug repro: export stalls at 99%",
  "Design review — new editor",
  "How to invite your team",
  "Keyboard shortcuts in 60 seconds",
  "Q3 roadmap",
];

function makeVideos() {
  return VIDEO_NAMES.map((fileName, i) => {
    const id = `lab-video-${i + 1}`;
    return {
      videoId: id,
      orgId: null,
      fileName,
      contentType: "video/mp4",
      fileSizeBytes: [48, 212, 31, 9, 156, 74, 22, 390][i] * 1024 * 1024,
      durationSeconds: [94, 312, 61, 18, 845, 127, 60, 1520][i],
      isPrivate: i === 2 || i === 3,
      createdAt: ago([3, 26, 50, 75, 120, 200, 300, 500][i]),
      url: `https://capturecat.so/share/${["7Kq2fX", "p9Lm2a", "Qw81zz", "bR4tYu", "Hn3k0p", "Zx5c7v", "Lm9nQe", "Tr2wB8"][i]}`,
      projectId: i % 3 === 0 ? `0E0F0A11-5A15-4C0E-8A11-00000000000${i}` : null,
      allowDownload: i % 2 === 0,
      hasPassword: i === 4,
      expiresAt: i === 1 ? "2026-12-31T23:59:59.000Z" : null,
      maxViews: i === 1 ? 500 : null,
      brandAccent: i === 0 ? "#0A84FF" : null,
      commentsEnabled: true,
      currentVersion: i === 0 ? 3 : 1,
      showVersionHistory: i === 0,
      ctaLabel: i === 0 ? "Book a demo" : null,
      ctaUrl: i === 0 ? "https://example.com/demo" : null,
      profileVisible: i < 3,
      thumbnailType: "image/svg+xml",
      thumbnailUrl: labPoster(i),
    };
  });
}

const PLAYLISTS = [
  { playlistId: "pl-1", name: "Onboarding", emoji: "🚀", videoIds: ["lab-video-1", "lab-video-6", "lab-video-7"], createdAt: ago(400) },
  { playlistId: "pl-2", name: "Releases", emoji: "📦", videoIds: ["lab-video-2", "lab-video-8"], createdAt: ago(300) },
  { playlistId: "pl-3", name: "Support", emoji: null, videoIds: ["lab-video-4"], createdAt: ago(200) },
];

function makeAnalytics(videoId: string) {
  const duration = 94;
  const heat = Array.from({ length: duration }, (_, s) => ({
    second: s,
    viewers: Math.round(420 * Math.exp(-s / 70) + 30 * Math.sin(s / 6) + (s > 40 && s < 52 ? 60 : 0) + 40),
  }));
  return {
    videoId,
    projectId: "0E0F0A11-5A15-4C0E-8A11-000000000000",
    durationSeconds: duration,
    views: 1284,
    plays: 962,
    completions: 431,
    ctaClicks: 118,
    ctaLabel: "Book a demo",
    ctaUrl: "https://example.com/demo",
    avgWatchedSeconds: 58,
    watchHeatmap: heat,
    dropOff: [3, 9, 15, 22, 30, 38, 46, 51, 60, 70, 80, 90].map((second, i) => ({
      second,
      sessions: [64, 41, 22, 18, 25, 19, 52, 14, 11, 9, 12, 31][i],
    })),
    clicks: [5, 12, 18, 33, 41, 47, 63, 72, 88].map((second, i) => ({
      second,
      count: [4, 9, 14, 6, 21, 17, 8, 5, 12][i],
    })),
    countries: [
      { country: "United States", count: 512 },
      { country: "United Kingdom", count: 233 },
      { country: "Germany", count: 141 },
      { country: "Canada", count: 96 },
      { country: "Japan", count: 58 },
    ],
    referrers: [
      { referrer: "Direct", count: 604 },
      { referrer: "slack.com", count: 288 },
      { referrer: "linear.app", count: 171 },
      { referrer: "mail.google.com", count: 94 },
    ],
    comments: [
      { commentId: "c1", authorName: "Priya", body: "The zoom on the settings panel makes this so much clearer.", videoTime: 41, createdAt: ago(20) },
      { commentId: "c2", authorName: "Marcus", body: "Can we cut the pause before the export step?", videoTime: 67, createdAt: ago(9) },
    ],
  };
}

function versionsFor(videoId: string) {
  return {
    videoId,
    currentVersion: 3,
    showVersionHistory: true,
    versions: [
      { version: 3, fileSizeBytes: 48 * 1024 * 1024, durationSeconds: 94, status: "ready", createdAt: ago(3), current: true },
      { version: 2, fileSizeBytes: 51 * 1024 * 1024, durationSeconds: 101, status: "ready", createdAt: ago(30), current: false },
      { version: 1, fileSizeBytes: 55 * 1024 * 1024, durationSeconds: 112, status: "ready", createdAt: ago(72), current: false },
    ],
  };
}

const ORG = { id: "org-acme", name: "Acme Inc", slug: "acme-x1y2", logo: null, createdAt: ago(900), metadata: null };

const FULL_ORG = {
  ...ORG,
  members: [
    { id: "m1", role: "owner", organizationId: ORG.id, userId: "lab-user", createdAt: ago(900), user: { id: "lab-user", name: "Mike Garland", email: "mike@acme.test", image: null } },
    { id: "m2", role: "admin", organizationId: ORG.id, userId: "u2", createdAt: ago(600), user: { id: "u2", name: "Priya Shah", email: "priya@acme.test", image: null } },
    { id: "m3", role: "member", organizationId: ORG.id, userId: "u3", createdAt: ago(300), user: { id: "u3", name: "Marcus Lee", email: "marcus@acme.test", image: null } },
  ],
  invitations: [{ id: "inv-1", email: "dana@acme.test", role: "member", status: "pending", organizationId: ORG.id, expiresAt: ago(-100) }],
};

const SSO = {
  enabled: true,
  canManage: true,
  role: "owner",
  signInUrl: "https://capturecat.so/login",
  providers: [
    {
      providerId: "acme-okta",
      type: "oidc",
      issuer: "https://acme.okta.com",
      domain: "acme.test",
      domainVerified: true,
      oidc: { discoveryEndpoint: "https://acme.okta.com/.well-known/openid-configuration", clientIdLastFour: "9f2c" },
      redirectUri: "https://api.capturecat.so/api/auth/sso/callback/acme-okta",
      samlAcsUrl: "https://api.capturecat.so/api/auth/sso/saml2/sp/acs/acme-okta",
      samlMetadataUrl: "https://api.capturecat.so/api/auth/sso/saml2/sp/metadata?providerId=acme-okta",
      dnsRecord: null,
    },
  ],
};

function trpcData(path: string, input: unknown, o: LabOptions): unknown {
  const empty = o.state === "empty";
  const videos = empty ? [] : makeVideos();
  switch (path) {
    case "videos.list":
      return {
        videos,
        storageUsedBytes: empty ? 0 : Math.round(61.4 * 1024 ** 3),
        storageLimitBytes: o.tier === "paid" ? 100 * 1024 ** 3 : 0,
      };
    case "videos.playlists":
      return { playlists: empty ? [] : PLAYLISTS };
    case "videos.uploadJobs":
      return {
        jobs:
          empty || !o.uploads
            ? []
            : [
                {
                  jobId: "job-1",
                  videoId: "lab-video-up",
                  projectId: null,
                  projectName: "Launch video",
                  fileName: "Launch video.mp4",
                  fileSizeBytes: 64 * 1024 * 1024,
                  state: "uploading",
                  progress: 0.62,
                  shareUrl: null,
                  error: null,
                  createdAt: NOW - 60_000,
                  updatedAt: NOW,
                },
              ],
      };
    case "videos.transcriptSearch":
      return {
        results: empty
          ? []
          : [
              {
                videoId: "lab-video-1",
                segments: [
                  { start: 12, end: 16, text: "Open Settings and choose Team to invite people." },
                  { start: 41, end: 45, text: "Every share link keeps the same address when you re-share." },
                ],
              },
            ],
      };
    case "videos.versions":
      return versionsFor((input as { videoId?: string })?.videoId ?? "lab-video-1");
    case "videos.analytics":
      return empty
        ? {
            ...makeAnalytics((input as { videoId?: string })?.videoId ?? "lab-video-1"),
            views: 0,
            plays: 0,
            completions: 0,
            ctaClicks: 0,
            avgWatchedSeconds: 0,
            ctaLabel: null,
            watchHeatmap: [],
            dropOff: [],
            clicks: [],
            countries: [],
            referrers: [],
            comments: [],
          }
        : makeAnalytics((input as { videoId?: string })?.videoId ?? "lab-video-1");
    case "videos.domains":
      return {
        enabled: o.tier === "paid",
        cnameTarget: "share.capturecat.so",
        domains: empty
          ? []
          : [
              { domain: "share.acme.test", verified: true, createdAt: ago(300) },
              { domain: "videos.acme.test", verified: false, createdAt: ago(5) },
            ],
      };
    case "storage.bucket":
    case "storage.connect":
      return {
        enabled: o.tier === "paid",
        available: true,
        bucket:
          empty && path === "storage.bucket"
            ? null
            : {
                id: "lab-bucket",
                provider: "r2",
                endpoint: "https://acme0000.r2.cloudflarestorage.com",
                region: "auto",
                bucket: "acme-videos",
                pathPrefix: "capturecat/",
                forcePathStyle: false,
                publicBaseUrl: null,
                accessKeyIdHint: "7f3a…c91e",
                verifiedAt: ago(60 * 24 * 3),
                videoCount: 14,
              },
        retainedCount: 0,
        corsOrigins: ["https://capturecat.so", "https://www.capturecat.so", "https://app.capturecat.so"],
      };
    case "billing.status":
      return { uid: "lab-user", email: "mike@acme.test", tier: o.tier, tester: false, blocked: false };
    case "profile.me":
      return {
        name: "Mike Garland",
        image: null,
        username: empty ? null : "mike",
        bio: empty ? null : "Product videos for CaptureCat.",
        website: empty ? null : "https://capturecat.so",
      };
    case "profile.checkUsername":
      return { available: true };
    case "sso.overview":
      return empty ? { ...SSO, enabled: o.tier === "paid", providers: [] } : SSO;
    default:
      // Mutations: succeed quietly with an empty object.
      return { ok: true };
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function respondTrpc(url: URL, o: LabOptions): Response {
  const paths = decodeURIComponent(url.pathname.split("/api/trpc/")[1] ?? "").split(",");
  let inputs: Record<string, unknown> = {};
  try {
    const raw = url.searchParams.get("input");
    if (raw) inputs = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    inputs = {};
  }
  const out = paths.map((p, i) => {
    const wrapped = inputs[String(i)] as { json?: unknown } | undefined;
    return { result: { data: superjson.serialize(trpcData(p, wrapped?.json, o)) } };
  });
  return json(out);
}

function respondRest(url: URL, o: LabOptions): Response | null {
  const p = url.pathname;
  const empty = o.state === "empty";
  const noTeam = empty || o.team === "none";
  if (p.endsWith("/api/auth/organization/list")) return json(noTeam ? [] : [ORG]);
  if (p.endsWith("/api/auth/organization/get-full-organization")) return json(noTeam ? null : FULL_ORG);
  if (p.endsWith("/api/auth/get-session"))
    return json({
      session: { id: "lab-session", userId: "lab-user", expiresAt: ago(-24) },
      user: { id: "lab-user", name: "Mike Garland", email: "mike@acme.test", image: null },
    });
  if (/\/api\/org\/[^/]+\/videos$/.test(p))
    return json({
      videos: empty
        ? []
        : makeVideos()
            .slice(0, 3)
            .map((v) => ({ videoId: v.videoId, fileName: v.fileName, createdAt: v.createdAt, url: v.url })),
    });
  if (p.endsWith("/api/plans"))
    return json({
      available: true,
      monthly: { amount: 1000, currency: "usd" },
      limits: {
        maxTotalStorageBytes: 100 * 1024 ** 3,
        maxFileSizeBytes: 5 * 1024 ** 3,
        maxDurationSeconds: 7200,
        maxUploadsPerDay: 200,
      },
    });
  if (p.endsWith("/api/cloud-projects"))
    return json({
      projects: empty
        ? []
        : [
            { projectId: "0E0F0A11-5A15-4C0E-8A11-000000000001", name: "Launch video", updatedAt: ago(1), revision: 7 },
            { projectId: "0E0F0A11-5A15-4C0E-8A11-000000000002", name: "Onboarding tour", updatedAt: ago(28), revision: 3 },
          ],
      storage: { usedBytes: 0, limitBytes: 0 },
    });
  if (p === "/__dev/local-projects")
    return json({
      projects: empty
        ? []
        : [
            { id: "LAB-LOCAL-1", name: "Design review — new editor", duration: 845, updatedAt: ago(4), aspectRatio: "16:9", thumbnail: labPoster(4) },
            { id: "LAB-LOCAL-2", name: "Bug repro: export stalls", duration: 18, updatedAt: ago(52), aspectRatio: "16:9", thumbnail: labPoster(3) },
            { id: "LAB-LOCAL-3", name: "iPhone app tour", duration: 72, updatedAt: ago(140), aspectRatio: "9:16", thumbnail: labPoster(5) },
          ],
    });
  return null;
}

let installed = false;

/** Wraps window.fetch for the lab page. Idempotent; DEV lab only. */
function installDashboardMocks(o: LabOptions): void {
  if (installed || typeof window === "undefined") return;
  installed = true;
  const real = window.fetch.bind(window);
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const raw = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const url = new URL(raw, window.location.href);
    const handled =
      url.pathname.includes("/api/trpc/") ||
      url.pathname.startsWith("/api/") ||
      url.pathname === "/__dev/local-projects";
    if (!handled) return real(input, init);
    if (o.cloudNetwork && /\/api\/cloud-projects\/./.test(url.pathname)) return real(input, init);
    if (o.state === "loading") return new Promise<Response>(() => {});
    await new Promise((r) => setTimeout(r, 60)); // a beat, like a network round trip
    if (url.pathname.includes("/api/trpc/")) return respondTrpc(url, o);
    return respondRest(url, o) ?? json({ ok: true });
  };
}

const query = typeof window === "undefined" ? new URLSearchParams() : new URLSearchParams(window.location.search);

/** The lab's options, read from the page URL. */
export const labOptions: LabOptions = {
  state: query.get("state") === "empty" ? "empty" : query.get("state") === "loading" ? "loading" : "full",
  tier: query.get("tier") === "free" ? "free" : "paid",
  team: query.get("team") === "none" ? "none" : "owner",
  uploads: query.get("uploads") !== "0",
  cloudNetwork: query.get("cloud") === "network",
};

// Installed while this module evaluates — DashboardLab imports it FIRST, so
// the wrapper is in place before Better Auth's client captures `fetch` (it
// binds the function once, at createAuthClient time).
installDashboardMocks(labOptions);
