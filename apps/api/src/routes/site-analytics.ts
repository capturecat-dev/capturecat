/**
 * Anonymous acquisition events from capturecat.so (migration 0030).
 *
 * The site posts one `visit` per page session, carrying the landing
 * attribution it captured in page memory — no cookie, no storage, no
 * identifier, so nothing here can link two events to one person. A `download`
 * is recorded by the DMG route itself (routes/releases.ts), from the same
 * fields passed as query parameters on the download link, so it counts even
 * when a script is blocked or the link was shared outside the site. What is
 * kept is deliberately coarse: a referrer HOST, the utm_* tags, a landing path
 * with capability ids collapsed, Cloudflare's country, and a device family.
 * No IP or UA string is written.
 *
 * Abuse is bounded the same way as the beta ingest: a per-IP limit in
 * src/index.ts, an Origin check (a browser on our site always sends one), and
 * a UA filter for crawlers and scripts. The answer is always 204 so a
 * rejected event teaches a script nothing.
 */

import { Hono } from "hono";
import type { Env } from "../types";
import { generateId } from "../lib/id";
import { webOrigins } from "../lib/origins";
import {
  cleanTag,
  deviceFromUserAgent,
  externalReferrerHost,
  isBotUserAgent,
  normalizeLandingPath,
} from "../lib/traffic-source";

export const siteAnalyticsRoutes = new Hono<{ Bindings: Env }>();

export interface SiteEventInput {
  type: "visit" | "download";
  /** A host or a full URL; internal and sign-in round-trip hosts are dropped. */
  referrer?: unknown;
  utmSource?: unknown;
  utmMedium?: unknown;
  utmCampaign?: unknown;
  path?: unknown;
  /** download: the architecture. */
  detail?: "arm64" | "x86_64" | null;
}

/** Writes one event unless the request is a crawler or script. */
export async function recordSiteEvent(env: Env, request: Request, e: SiteEventInput): Promise<void> {
  const ua = request.headers.get("User-Agent");
  if (isBotUserAgent(ua)) return;
  const cf = (request as Request & { cf?: { country?: string } }).cf;

  await env.DB.prepare(
    `INSERT INTO site_events
       (id, type, created_at, referrer_host, utm_source, utm_medium, utm_campaign,
        landing_path, country, device, detail)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  )
    .bind(
      generateId(),
      e.type,
      new Date().toISOString(),
      externalReferrerHost(typeof e.referrer === "string" ? e.referrer : null),
      cleanTag(e.utmSource),
      cleanTag(e.utmMedium),
      cleanTag(e.utmCampaign),
      normalizeLandingPath(e.path),
      cf?.country ?? null,
      deviceFromUserAgent(ua),
      e.detail ?? null,
    )
    .run();
}

interface VisitBody {
  referrer?: unknown;
  utmSource?: unknown;
  utmMedium?: unknown;
  utmCampaign?: unknown;
  path?: unknown;
}

siteAnalyticsRoutes.post("/site/visit", async (c) => {
  const done = () => c.body(null, 204);

  const origin = c.req.header("Origin");
  if (!origin || !webOrigins(c.env).includes(origin)) return done();

  // navigator.sendBeacon posts text/plain (a CORS-safelisted type, so no
  // preflight); parse the JSON out of the text either way.
  let body: VisitBody;
  try {
    const text = await c.req.text();
    if (text.length > 2_000) return done();
    body = JSON.parse(text) as VisitBody;
  } catch {
    return done();
  }
  if (typeof body !== "object" || body === null) return done();

  await recordSiteEvent(c.env, c.req.raw, { type: "visit", ...body });
  return done();
});
