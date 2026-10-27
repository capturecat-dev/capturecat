/**
 * Admin analytics: who the users are, where they came from, what they do and
 * what they store. Read-only aggregates over tables that already exist, plus
 * the acquisition columns/events of migration 0030.
 *
 * STORAGE here is bytes on CaptureCat's own R2 — the same sources and the same
 * BYO-bucket exclusion as STORAGE_SUM_SQL in lib/db.ts (a video in a user's own
 * bucket costs us nothing) — plus cloud-project history snapshots, which sit
 * under their own cap but are still bytes we hold.
 *
 * "Last active" is the latest of: the session's sliding refresh (Better Auth
 * bumps `session.updatedAt` at most once a day, so it is day-granular), a
 * finished upload, and a cloud-project save. Recording and exporting happen
 * on the Mac and never reach the server, so a user who only records locally
 * is active only through their session.
 *
 * Mounted behind the admin role gate in admin.ts.
 */

import type { Hono } from "hono";
import type { Env, Variables } from "../types";
import { PAID_SUBSCRIPTION_STATUSES } from "../lib/stripe";
import { classifySource, deviceFromUserAgent, type SourceKind } from "../lib/traffic-source";
import { utmSourceOf } from "../lib/signup-attribution";

type App = Hono<{ Bindings: Env; Variables: Variables }>;

export interface UserUsage {
  storageBytes: number;
  videoBytes: number;
  projectBytes: number;
  screenshotBytes: number;
  videos: number;
  videoSeconds: number;
  projects: number;
  screenshots: number;
  views: number;
  lastSeen: string | null;
  lastActive: string | null;
}

const emptyUsage = (): UserUsage => ({
  storageBytes: 0, videoBytes: 0, projectBytes: 0, screenshotBytes: 0,
  videos: 0, videoSeconds: 0, projects: 0, screenshots: 0, views: 0,
  lastSeen: null, lastActive: null,
});

const latest = (...xs: Array<string | null | undefined>): string | null =>
  xs.reduce<string | null>((a, b) => (b && (!a || b > a) ? b : a), null);

/**
 * Per-user usage for every user that has any, in one D1 batch of grouped
 * queries (not a correlated subquery per row).
 */
export async function usageByUser(db: D1Database): Promise<Map<string, UserUsage>> {
  const [videos, videoBytes, projects, projectObjects, history, shots, sessions, views] = await db.batch([
    db.prepare(
      `SELECT uid, COUNT(*) AS n, COALESCE(SUM(duration_seconds), 0) AS secs, MAX(created_at) AS last
         FROM shared_videos WHERE status = 'ready' GROUP BY uid`
    ),
    db.prepare(
      `SELECT uid, SUM(sz) AS bytes FROM (
         SELECT sv.uid AS uid, vv.file_size_bytes AS sz
           FROM video_versions vv JOIN shared_videos sv ON sv.video_id = vv.video_id
          WHERE vv.status = 'ready' AND vv.storage_id IS NULL
         UNION ALL
         SELECT sv.uid, sv.file_size_bytes
           FROM shared_videos sv
          WHERE sv.status = 'ready' AND sv.storage_id IS NULL
            AND NOT EXISTS (SELECT 1 FROM video_versions vv WHERE vv.video_id = sv.video_id)
       ) GROUP BY uid`
    ),
    db.prepare(
      `SELECT owner_uid AS uid, COUNT(*) AS n, COALESCE(SUM(doc_bytes), 0) AS bytes, MAX(updated_at) AS last
         FROM cloud_projects GROUP BY owner_uid`
    ),
    db.prepare(
      `SELECT owner_uid AS uid, SUM(bytes) AS bytes FROM cloud_project_objects
        WHERE status = 'ready' GROUP BY owner_uid`
    ),
    db.prepare(
      `SELECT cp.owner_uid AS uid, SUM(v.stored_bytes) AS bytes
         FROM cloud_project_versions v JOIN cloud_projects cp ON cp.id = v.project_id
        GROUP BY cp.owner_uid`
    ),
    db.prepare(`SELECT uid, COUNT(*) AS n, SUM(bytes) AS bytes FROM stored_objects GROUP BY uid`),
    db.prepare(`SELECT "userId" AS uid, MAX("updatedAt") AS last FROM "session" GROUP BY "userId"`),
    db.prepare(
      `SELECT sv.uid AS uid, COUNT(*) AS n
         FROM video_views vw JOIN shared_videos sv ON sv.video_id = vw.video_id
        GROUP BY sv.uid`
    ),
  ]);

  const map = new Map<string, UserUsage>();
  const at = (uid: string) => {
    let u = map.get(uid);
    if (!u) map.set(uid, (u = emptyUsage()));
    return u;
  };
  type Row = { uid: string; n?: number; secs?: number; bytes?: number; last?: string | null };
  const rows = (r: D1Result) => (r.results ?? []) as Row[];

  for (const r of rows(videos)) {
    const u = at(r.uid);
    u.videos = r.n ?? 0;
    u.videoSeconds = Math.round(r.secs ?? 0);
    u.lastActive = latest(u.lastActive, r.last);
  }
  for (const r of rows(videoBytes)) at(r.uid).videoBytes = r.bytes ?? 0;
  for (const r of rows(projects)) {
    const u = at(r.uid);
    u.projects = r.n ?? 0;
    u.projectBytes += r.bytes ?? 0;
    u.lastActive = latest(u.lastActive, r.last);
  }
  for (const r of rows(projectObjects)) at(r.uid).projectBytes += r.bytes ?? 0;
  for (const r of rows(history)) at(r.uid).projectBytes += r.bytes ?? 0;
  for (const r of rows(shots)) {
    const u = at(r.uid);
    u.screenshots = r.n ?? 0;
    u.screenshotBytes = r.bytes ?? 0;
  }
  for (const r of rows(sessions)) {
    const u = at(r.uid);
    u.lastSeen = r.last ?? null;
    u.lastActive = latest(u.lastActive, r.last);
  }
  for (const r of rows(views)) at(r.uid).views = r.n ?? 0;
  for (const u of map.values()) u.storageBytes = u.videoBytes + u.projectBytes + u.screenshotBytes;
  return map;
}

export interface SignupSource {
  country: string | null;
  via: string | null;
  source: { id: string; label: string; kind: SourceKind } | null;
  referrer: string | null;
  utm: string | null;
  landing: string | null;
}

/** NULL `via` = signed up before migration 0030: nothing is known. */
export function signupSource(r: {
  signupCountry: string | null;
  signupVia: string | null;
  signupReferrer: string | null;
  signupUtm: string | null;
  signupLanding: string | null;
}): SignupSource {
  return {
    country: r.signupCountry,
    via: r.signupVia,
    source: r.signupVia ? classifySource(r.signupReferrer, utmSourceOf(r.signupUtm)) : null,
    referrer: r.signupReferrer,
    utm: r.signupUtm,
    landing: r.signupLanding,
  };
}

const DEVICE_NAME: Record<string, string> = {
  mac: "Mac", windows: "Windows", ios: "iPhone/iPad", android: "Android", linux: "Linux", other: "Other device",
};

/** "Mac · Safari" from a session's user agent. */
export function describeUserAgent(ua: string | null): string {
  if (!ua) return "Unknown device";
  const browser = /CaptureCat|CFNetwork/.test(ua)
    ? "CaptureCat app"
    : /Edg\//.test(ua)
      ? "Edge"
      : /Firefox\//.test(ua)
        ? "Firefox"
        : /Chrome\//.test(ua)
          ? "Chrome"
          : /Safari\//.test(ua)
            ? "Safari"
            : null;
  const device = DEVICE_NAME[deviceFromUserAgent(ua)];
  return browser ? `${device} · ${browser}` : device!;
}

const RANGES = new Set([7, 30, 90, 365]);
const DAY = 86_400_000;

interface Bucket { visits: number; downloads: number; signups: number }
const bump = <K extends string>(m: Map<K, Bucket>, k: K, field: keyof Bucket, n: number) => {
  const b = m.get(k) ?? { visits: 0, downloads: 0, signups: 0 };
  b[field] += n;
  m.set(k, b);
};
const eventField = (type: string): keyof Bucket => (type === "download" ? "downloads" : "visits");

export function registerAnalyticsAdminRoutes(app: App): void {
  app.get("/admin/analytics", async (c) => {
    const db = c.env.DB;
    const requested = Number(c.req.query("days"));
    const days = RANGES.has(requested) ? requested : 30;
    const now = Date.now();
    const since = new Date(now - days * DAY).toISOString();
    const sinceDay = since.slice(0, 10);
    const sinceMonth = since.slice(0, 7).replace("-", "");
    const paid = PAID_SUBSCRIPTION_STATUSES.map(() => "?").join(",");

    const [
      userCounts, signups, evDaily, evSourceLanding, evCountry, evDevice,
      uploadsDaily, viewsInRange, edits, providers, features, featuresInRange, orgs,
    ] = await db.batch([
      db.prepare(
        `SELECT COUNT(*) AS users,
                SUM(CASE WHEN tester = 1 THEN 1 ELSE 0 END) AS testers,
                (SELECT COUNT(DISTINCT referenceId) FROM subscription WHERE status IN (${paid})) AS paid
           FROM user`
      ).bind(...PAID_SUBSCRIPTION_STATUSES),
      db.prepare(
        `SELECT createdAt, signupCountry, signupVia, signupReferrer, signupUtm, signupLanding
           FROM user WHERE createdAt >= ?`
      ).bind(since),
      db.prepare(
        `SELECT substr(created_at, 1, 10) AS d, type, COUNT(*) AS n FROM site_events
          WHERE created_at >= ? GROUP BY d, type`
      ).bind(since),
      // Source × landing page in one grouping: the sources table, the landing
      // table, and "what does Google / ChatGPT send people to" all fold from it.
      db.prepare(
        `SELECT referrer_host, utm_source, landing_path, type, COUNT(*) AS n FROM site_events
          WHERE created_at >= ? GROUP BY referrer_host, utm_source, landing_path, type`
      ).bind(since),
      db.prepare(
        `SELECT country, type, COUNT(*) AS n FROM site_events
          WHERE created_at >= ? GROUP BY country, type`
      ).bind(since),
      db.prepare(
        `SELECT device, type, COUNT(*) AS n FROM site_events
          WHERE created_at >= ? GROUP BY device, type`
      ).bind(since),
      db.prepare(
        `SELECT substr(created_at, 1, 10) AS d, COUNT(*) AS n FROM shared_videos
          WHERE status = 'ready' AND created_at >= ? GROUP BY d`
      ).bind(since),
      db.prepare(`SELECT COUNT(*) AS n FROM video_views WHERE created_at >= ?`).bind(since),
      // A history version is one editing window on a project (lib/project-history.ts),
      // so this counts editing sessions, split by app and by human vs agent.
      db.prepare(
        `SELECT client_kind, source, COUNT(*) AS n, COUNT(DISTINCT project_id) AS projects
           FROM cloud_project_versions WHERE opened_at >= ? GROUP BY client_kind, source`
      ).bind(since),
      db.prepare(`SELECT "providerId" AS provider, COUNT(DISTINCT "userId") AS n FROM "account" GROUP BY "providerId"`),
      db.prepare(
        `SELECT
           (SELECT COUNT(DISTINCT uid) FROM shared_videos WHERE status = 'ready') AS shared,
           (SELECT COUNT(DISTINCT owner_uid) FROM cloud_projects) AS cloud,
           (SELECT COUNT(DISTINCT user_id) FROM screenshot_usage) AS shotApi,
           (SELECT COUNT(DISTINCT uid) FROM stored_objects) AS shotStored,
           (SELECT COUNT(DISTINCT uid) FROM shared_videos WHERE ai_summary IS NOT NULL) AS ai,
           (SELECT COUNT(DISTINCT sv.uid) FROM video_comments vc JOIN shared_videos sv ON sv.video_id = vc.video_id) AS comments,
           (SELECT COUNT(DISTINCT sv.uid) FROM video_views vw JOIN shared_videos sv ON sv.video_id = vw.video_id) AS viewed,
           (SELECT COUNT(DISTINCT uid) FROM video_playlists) AS playlists,
           (SELECT COUNT(DISTINCT uid) FROM custom_domains WHERE verified = 1) AS domains,
           (SELECT COUNT(DISTINCT uid) FROM storage_buckets WHERE active = 1) AS byo,
           (SELECT COUNT(DISTINCT "userId") FROM "member") AS teams`
      ),
      db.prepare(
        `SELECT
           (SELECT COUNT(DISTINCT uid) FROM shared_videos WHERE status = 'ready' AND created_at >= ?1) AS shared,
           (SELECT COUNT(DISTINCT owner_uid) FROM cloud_projects WHERE updated_at >= ?1) AS cloud,
           (SELECT COUNT(DISTINCT user_id) FROM screenshot_usage WHERE yyyymm >= ?2) AS shotApi,
           (SELECT COUNT(DISTINCT uid) FROM stored_objects WHERE created_at >= ?1) AS shotStored,
           (SELECT COUNT(DISTINCT uid) FROM shared_videos WHERE ai_summary IS NOT NULL AND created_at >= ?1) AS ai,
           (SELECT COUNT(DISTINCT sv.uid) FROM video_comments vc JOIN shared_videos sv ON sv.video_id = vc.video_id
             WHERE vc.created_at >= ?1) AS comments,
           (SELECT COUNT(DISTINCT sv.uid) FROM video_views vw JOIN shared_videos sv ON sv.video_id = vw.video_id
             WHERE vw.created_at >= ?1) AS viewed`
      ).bind(since, sinceMonth),
      db.prepare(`SELECT COUNT(*) AS n FROM "organization"`),
    ]);

    type R = Record<string, unknown>;
    const all = (r: D1Result) => (r.results ?? []) as R[];
    const first = (r: D1Result) => all(r)[0] ?? {};
    const num = (v: unknown) => (typeof v === "number" ? v : 0);

    // ---- usage + storage, from the same per-user map the Users table uses
    const usage = await usageByUser(db);
    const activeWithin = (ms: number) => {
      const cutoff = new Date(now - ms).toISOString();
      let n = 0;
      for (const u of usage.values()) if (u.lastActive && u.lastActive >= cutoff) n++;
      return n;
    };
    const storage = { totalBytes: 0, videoBytes: 0, projectBytes: 0, screenshotBytes: 0, usersStoring: 0 };
    let videos = 0, videoSeconds = 0, projects = 0, screenshots = 0;
    for (const u of usage.values()) {
      storage.totalBytes += u.storageBytes;
      storage.videoBytes += u.videoBytes;
      storage.projectBytes += u.projectBytes;
      storage.screenshotBytes += u.screenshotBytes;
      if (u.storageBytes > 0) storage.usersStoring++;
      videos += u.videos;
      videoSeconds += u.videoSeconds;
      projects += u.projects;
      screenshots += u.screenshots;
    }

    const topIds = [...usage.entries()]
      .filter(([, u]) => u.storageBytes > 0)
      .sort((a, b) => b[1].storageBytes - a[1].storageBytes)
      .slice(0, 10);
    const topUsers = topIds.length
      ? all(
          await db
            .prepare(`SELECT id, email, name FROM user WHERE id IN (${topIds.map(() => "?").join(",")})`)
            .bind(...topIds.map(([id]) => id))
            .all()
        )
      : [];
    const byId = new Map(topUsers.map((u) => [u.id as string, u]));

    // ---- daily series, zero-filled
    const daily = new Map<string, { visits: number; downloads: number; signups: number; uploads: number }>();
    for (let t = Date.parse(`${sinceDay}T00:00:00Z`); t <= now; t += DAY) {
      daily.set(new Date(t).toISOString().slice(0, 10), { visits: 0, downloads: 0, signups: 0, uploads: 0 });
    }
    for (const r of all(evDaily)) {
      const d = daily.get(r.d as string);
      if (d) d[eventField(r.type as string)] += num(r.n);
    }
    for (const r of all(uploadsDaily)) {
      const d = daily.get(r.d as string);
      if (d) d.uploads += num(r.n);
    }

    // ---- acquisition: events and sign-ups folded into one table per dimension
    const sources = new Map<string, Bucket>();
    const sourceMeta = new Map<string, { label: string; kind: SourceKind }>();
    const referrers = new Map<string, Map<string, number>>();
    const landings = new Map<string, Bucket>();
    // source id → landing path → counts, and the transpose for the landing table
    const sourceLandings = new Map<string, Map<string, Bucket>>();
    const landingSources = new Map<string, Map<string, Bucket>>();
    const cross = (sourceId: string, path: string, field: keyof Bucket, n: number) => {
      const byPath = sourceLandings.get(sourceId) ?? new Map<string, Bucket>();
      bump(byPath, path, field, n);
      sourceLandings.set(sourceId, byPath);
      const bySource = landingSources.get(path) ?? new Map<string, Bucket>();
      bump(bySource, sourceId, field, n);
      landingSources.set(path, bySource);
    };
    for (const r of all(evSourceLanding)) {
      const s = classifySource(r.referrer_host as string | null, r.utm_source as string | null);
      const path = (r.landing_path as string | null) ?? "?";
      const field = eventField(r.type as string);
      sourceMeta.set(s.id, { label: s.label, kind: s.kind });
      bump(sources, s.id, field, num(r.n));
      bump(landings, path, field, num(r.n));
      cross(s.id, path, field, num(r.n));
      const host = (r.referrer_host as string | null) ?? (r.utm_source ? `utm: ${r.utm_source}` : null);
      if (host && r.type === "visit") {
        const hosts = referrers.get(s.id) ?? new Map<string, number>();
        hosts.set(host, (hosts.get(host) ?? 0) + num(r.n));
        referrers.set(s.id, hosts);
      }
    }
    const countries = new Map<string, Bucket>();
    for (const r of all(evCountry)) bump(countries, (r.country as string | null) ?? "??", eventField(r.type as string), num(r.n));
    const devices = new Map<string, Bucket>();
    for (const r of all(evDevice)) bump(devices, (r.device as string | null) ?? "other", eventField(r.type as string), num(r.n));

    const via = { web: 0, desktop: 0, unknown: 0 };
    for (const r of all(signups)) {
      const day = daily.get((r.createdAt as string).slice(0, 10));
      if (day) day.signups++;
      const s = signupSource(r as unknown as Parameters<typeof signupSource>[0]);
      if (s.via === "web" || s.via === "desktop") via[s.via]++;
      else via.unknown++;
      // Pre-0030 users have no source at all — "unknown", not "direct".
      const src = s.source ?? { id: "unknown", label: "Unknown (before tracking)", kind: "direct" as const };
      // A Mac-app sign-up starts with no web page behind it: its source is
      // unknowable at sign-up, so it is kept apart from genuine direct visits.
      const key = s.via === "desktop" && src.id === "direct" ? "mac-app" : src.id;
      sourceMeta.set(key, key === "mac-app" ? { label: "Mac app sign-in (source not visible)", kind: "direct" } : { label: src.label, kind: src.kind });
      bump(sources, key, "signups", 1);
      bump(countries, s.country ?? "??", "signups", 1);
      // Only a web sign-up knows the page its visit started on.
      if (s.landing) {
        bump(landings, s.landing, "signups", 1);
        cross(key, s.landing, "signups", 1);
      }
    }

    const table = <K extends string>(m: Map<K, Bucket>) =>
      [...m.entries()].sort((a, b) => b[1].visits + b[1].signups * 100 - (a[1].visits + a[1].signups * 100));

    const f = first(features);
    const fr = first(featuresInRange);
    const feature = (id: string, label: string, inRange: boolean) => ({
      id, label, users: num(f[id]), usersInRange: inRange ? num(fr[id]) : null,
    });

    return c.json({
      range: { days, since },
      totals: {
        users: num(first(userCounts).users),
        testers: num(first(userCounts).testers),
        paid: num(first(userCounts).paid),
        signups: all(signups).length,
        active1d: activeWithin(DAY),
        active7d: activeWithin(7 * DAY),
        active30d: activeWithin(30 * DAY),
        visits: [...daily.values()].reduce((a, d) => a + d.visits, 0),
        downloads: [...daily.values()].reduce((a, d) => a + d.downloads, 0),
        uploads: [...daily.values()].reduce((a, d) => a + d.uploads, 0),
        views: num(first(viewsInRange).n),
        videos, videoSeconds, projects, screenshots,
        orgs: num(first(orgs).n),
      },
      storage,
      daily: [...daily.entries()].map(([day, d]) => ({ day, ...d })),
      sources: table(sources).map(([id, b]) => ({
        id,
        ...(sourceMeta.get(id) ?? { label: id, kind: "referral" as SourceKind }),
        ...b,
        hosts: [...(referrers.get(id)?.entries() ?? [])]
          .sort((a, b) => b[1] - a[1]).slice(0, 5).map(([host, visits]) => ({ host, visits })),
        landings: table(sourceLandings.get(id) ?? new Map<string, Bucket>())
          .slice(0, 10).map(([path, lb]) => ({ path, ...lb })),
      })),
      countries: table(countries).map(([country, b]) => ({ country, ...b })).slice(0, 40),
      landings: table(landings).slice(0, 25).map(([path, b]) => ({
        path,
        ...b,
        sources: table(landingSources.get(path) ?? new Map<string, Bucket>())
          .slice(0, 4)
          .map(([sid, sb]) => ({ id: sid, label: sourceMeta.get(sid)?.label ?? sid, visits: sb.visits, signups: sb.signups })),
      })),
      devices: table(devices).map(([device, b]) => ({ device, visits: b.visits, downloads: b.downloads })),
      signupVia: via,
      providers: all(providers).map((r) => ({ provider: r.provider as string, users: num(r.n) })),
      edits: all(edits).map((r) => ({
        client: r.client_kind as string, source: r.source as string, sessions: num(r.n), projects: num(r.projects),
      })),
      features: [
        feature("shared", "Shared a video", true),
        feature("viewed", "Got viewers on a share", true),
        feature("comments", "Got comments", true),
        feature("ai", "AI summaries", true),
        feature("cloud", "Cloud projects", true),
        feature("shotApi", "Screenshot API", true),
        feature("shotStored", "Stored screenshots", true),
        feature("playlists", "Playlists", false),
        feature("domains", "Custom domain", false),
        feature("byo", "Own storage bucket", false),
        feature("teams", "In a team", false),
      ],
      topUsers: topIds.map(([id, u]) => ({
        id,
        email: (byId.get(id)?.email as string | undefined) ?? id,
        name: (byId.get(id)?.name as string | null | undefined) ?? null,
        ...u,
      })),
    });
  });

  /**
   * GET /admin/users/:id/activity — one user's footprint: what they store,
   * what they shared and how it was watched, their projects, devices.
   * Titles and file names are shown because the operator already holds the
   * objects themselves; nothing here is new data.
   */
  app.get("/admin/users/:id/activity", async (c) => {
    const db = c.env.DB;
    const id = c.req.param("id");
    const [user, videos, projects, sessions, accounts, shots, shotApi, edits] = await db.batch([
      db.prepare(
        `SELECT id, email, name, createdAt, signupCountry, signupVia, signupReferrer, signupUtm, signupLanding
           FROM user WHERE id = ?`
      ).bind(id),
      db.prepare(
        `SELECT sv.video_id, COALESCE(sv.ai_title, sv.file_name) AS title, sv.file_size_bytes, sv.duration_seconds,
                sv.is_private, sv.storage_id, sv.created_at, sv.current_version,
                (SELECT COUNT(*) FROM video_views vw WHERE vw.video_id = sv.video_id) AS views,
                (SELECT COUNT(*) FROM video_comments vc WHERE vc.video_id = sv.video_id) AS comments
           FROM shared_videos sv WHERE sv.uid = ? AND sv.status = 'ready'
          ORDER BY sv.created_at DESC LIMIT 50`
      ).bind(id),
      db.prepare(
        `SELECT cp.id, cp.name, cp.org_id, cp.created_at, cp.updated_at,
                cp.doc_bytes
                  + COALESCE((SELECT SUM(bytes) FROM cloud_project_objects o WHERE o.project_id = cp.id AND o.status = 'ready'), 0)
                  AS bytes,
                COALESCE((SELECT SUM(stored_bytes) FROM cloud_project_versions v WHERE v.project_id = cp.id), 0) AS history_bytes,
                (SELECT COUNT(*) FROM cloud_project_versions v WHERE v.project_id = cp.id) AS versions
           FROM cloud_projects cp WHERE cp.owner_uid = ?
          ORDER BY cp.updated_at DESC LIMIT 50`
      ).bind(id),
      db.prepare(
        `SELECT "userAgent" AS ua, "createdAt" AS created, "updatedAt" AS updated
           FROM "session" WHERE "userId" = ? ORDER BY "updatedAt" DESC LIMIT 10`
      ).bind(id),
      db.prepare(`SELECT "providerId" AS provider, "createdAt" AS created FROM "account" WHERE "userId" = ?`).bind(id),
      db.prepare(`SELECT COUNT(*) AS n, COALESCE(SUM(bytes), 0) AS bytes FROM stored_objects WHERE uid = ?`).bind(id),
      db.prepare(`SELECT yyyymm, count FROM screenshot_usage WHERE user_id = ? ORDER BY yyyymm DESC LIMIT 6`).bind(id),
      db.prepare(
        `SELECT client_kind, source, COUNT(*) AS n, MAX(updated_at) AS last FROM cloud_project_versions
          WHERE actor_uid = ? GROUP BY client_kind, source`
      ).bind(id),
    ]);

    type R = Record<string, unknown>;
    const all = (r: D1Result) => (r.results ?? []) as R[];
    const u = all(user)[0];
    if (!u) return c.json({ error: "Not found" }, 404);
    const usage = (await usageByUser(db)).get(id) ?? emptyUsage();

    return c.json({
      user: { id: u.id, email: u.email, name: u.name, createdAt: u.createdAt },
      signup: signupSource(u as unknown as Parameters<typeof signupSource>[0]),
      usage,
      providers: all(accounts).map((a) => a.provider as string),
      sessions: all(sessions).map((s) => ({
        // A Mac-app sign-in's session is minted by the BROWSER's OAuth
        // callback too, so the UA names the device and browser that signed
        // in, never "app vs web" — it is reported as just that.
        client: describeUserAgent(s.ua as string | null),
        userAgent: s.ua as string | null,
        created: s.created as string,
        lastSeen: s.updated as string,
      })),
      videos: all(videos).map((v) => ({
        id: v.video_id as string,
        title: v.title as string,
        bytes: v.file_size_bytes as number,
        seconds: v.duration_seconds as number,
        private: v.is_private === 1,
        ownBucket: v.storage_id != null,
        versions: v.current_version as number,
        views: v.views as number,
        comments: v.comments as number,
        createdAt: v.created_at as string,
      })),
      projects: all(projects).map((p) => ({
        id: p.id as string,
        name: p.name as string,
        team: p.org_id != null,
        bytes: p.bytes as number,
        historyBytes: p.history_bytes as number,
        versions: p.versions as number,
        createdAt: p.created_at as string,
        updatedAt: p.updated_at as string,
      })),
      screenshots: {
        stored: (all(shots)[0]?.n as number) ?? 0,
        bytes: (all(shots)[0]?.bytes as number) ?? 0,
        apiByMonth: all(shotApi).map((r) => ({ month: r.yyyymm as string, count: r.count as number })),
      },
      edits: all(edits).map((e) => ({
        client: e.client_kind as string, source: e.source as string, sessions: e.n as number, last: e.last as string,
      })),
    });
  });
}
