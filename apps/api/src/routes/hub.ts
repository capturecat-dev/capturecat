import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement, userRateLimit } from "../lib/entitlement";
import { z } from "zod";
import { featuresForTier } from "../lib/plans";
import { planForUser } from "../lib/entitlement";
import { parseJsonBody } from "../lib/validate";
import {
  cnameTarget,
  createCustomHostname,
  deleteCustomHostname,
  getCustomHostname,
  saasConfigured,
  type CustomHostname,
} from "../lib/cloudflare-saas";
import { generateId } from "../lib/id";
import {
  deleteDomain,
  domainIsLive,
  getDomain,
  setDomainCloudflareState,
  type CustomDomain,
  getAISummary,
  getSharedVideo,
  getTranscript,
  insertDomain,
  setReaction,
  myReaction,
  isAllowedReaction,
  listDomains,
  listReactions,
  reactionCount,
  resolveDomain,
  searchTranscripts,
  setAISummary,
  setDomainVerified,
} from "../lib/db";

/**
 * Hub batch 2: reactions, transcripts, AI summaries and custom domains.
 * Public reads share the comments trust model (rate limits + caps, no auth);
 * everything owner-facing rides requireAuth, and the Pro-only surfaces check
 * the plan flags (deny-by-default — see lib/plans.ts).
 */
export const hubRoutes = new Hono<{
  Bindings: Env;
  Variables: Variables;
}>();

/** Same visibility gate the share page's public endpoints apply. */
async function publicVideo(db: D1Database, videoId: string) {
  const doc = await getSharedVideo(db, videoId);
  if (!doc || doc.status !== "ready" || doc.isPrivate) return null;
  return doc;
}

// ---------------------------------------------------------------------------
// Reactions
// ---------------------------------------------------------------------------

const MAX_REACTIONS_PER_VIDEO = 2000;

hubRoutes.get("/video/:videoId/reactions", async (c) => {
  const doc = await publicVideo(c.env.DB, c.req.param("videoId"));
  if (!doc) return c.json({ error: "Video not found" }, 404);
  const session = c.req.query("session");
  const mine =
    session && /^[A-Za-z0-9_-]{8,64}$/.test(session)
      ? await myReaction(c.env.DB, doc.videoId, session)
      : null;
  return c.json({ reactions: await listReactions(c.env.DB, doc.videoId), mine });
});

hubRoutes.post("/video/:videoId/reactions", async (c) => {
  const doc = await publicVideo(c.env.DB, c.req.param("videoId"));
  if (!doc) return c.json({ error: "Video not found" }, 404);

  // Per-IP budget, mirroring the comment limiter.
  const ip = c.req.header("CF-Connecting-IP") ?? "unknown";
  const windowKey = Math.floor(Date.now() / 60_000);
  const rateKey = new Request(
    `https://rate-limit.internal/reactions/${encodeURIComponent(ip)}/${windowKey}`
  );
  const cached = await caches.default.match(rateKey);
  const count = cached ? parseInt(await cached.text(), 10) : 0;
  if (count >= 30) return c.json({ ok: true }, 202);
  await caches.default.put(
    rateKey,
    new Response(String(count + 1), { headers: { "Cache-Control": "s-maxage=60" } })
  );

  const body: { emoji?: unknown; videoTime?: unknown; sessionId?: unknown } =
    await c.req.json().catch(() => ({}));
  const emoji = typeof body.emoji === "string" ? body.emoji : "";
  if (!isAllowedReaction(emoji)) return c.json({ error: "Unknown reaction" }, 400);
  const sessionId =
    typeof body.sessionId === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(body.sessionId)
      ? body.sessionId
      : "anon";
  const t =
    typeof body.videoTime === "number" && isFinite(body.videoTime)
      ? Math.min(Math.max(0, body.videoTime), Math.max(0, doc.durationSeconds))
      : 0;

  if ((await reactionCount(c.env.DB, doc.videoId)) >= MAX_REACTIONS_PER_VIDEO) {
    return c.json({ ok: true, mine: null }, 202);
  }
  const mine = await setReaction(
    c.env.DB, generateId(), doc.videoId, sessionId, emoji, Math.round(t * 10) / 10
  );
  return c.json({ ok: true, mine });
});

// ---------------------------------------------------------------------------
// Transcripts
// ---------------------------------------------------------------------------

hubRoutes.get("/video/:videoId/transcript", async (c) => {
  const doc = await publicVideo(c.env.DB, c.req.param("videoId"));
  if (!doc) return c.json({ error: "Video not found" }, 404);
  const segments = await getTranscript(c.env.DB, doc.videoId);
  return c.json({ segments: segments ?? [] });
});

/** Library-wide transcript search for the dashboard. */
hubRoutes.get("/transcripts/search", requireAuth, async (c) => {
  const q = (c.req.query("q") ?? "").trim();
  if (q.length < 2) return c.json({ results: [] });
  const results = await searchTranscripts(c.env.DB, c.get("user").uid, q.slice(0, 80));
  return c.json({ results });
});

// ---------------------------------------------------------------------------
// AI summary — server-side Gemini path (the app's local model uploads its
// results with the share instead; see routes/upload.ts)
// ---------------------------------------------------------------------------

hubRoutes.post(
  "/video/:videoId/ai-summary",
  requireAuth,
  requireEntitlement(),
  // Each call re-sends up to 30k chars of transcript to Gemini — bound it.
  userRateLimit({ limit: 5, windowSec: 60, scope: "ai-summary" }),
  async (c) => {
    const doc = await getSharedVideo(c.env.DB, c.req.param("videoId"));
    if (!doc) return c.json({ error: "Video not found" }, 404);
    if (doc.uid !== c.get("user").uid) return c.json({ error: "Forbidden" }, 403);

    const features = await featuresForTier(c.env.DB, c.get("entitlement").tier, c.get("entitlement").planName);
    if (!features.aiSummaries) {
      return c.json({ error: "AI summaries require CaptureCat Pro" }, 402);
    }
    if (!c.env.GEMINI_API_KEY) {
      return c.json({ error: "AI is not configured on this server" }, 503);
    }

    const segments = await getTranscript(c.env.DB, doc.videoId);
    if (!segments || segments.length === 0) {
      return c.json({ error: "No transcript for this video yet" }, 400);
    }

    const transcriptText = segments
      .map((s) => `[${Math.floor(s.start)}s] ${s.text}`)
      .join("\n")
      .slice(0, 30_000);

    const prompt =
      "You are titling a screen recording for its share page. Given the " +
      "timestamped transcript, return STRICT JSON (no markdown fence) shaped " +
      '{"title": string (max 60 chars), "summary": string (2-3 sentences), ' +
      '"chapters": [{"start": number (seconds), "label": string (max 40 chars)}] ' +
      "(3-8 chapters at natural topic changes)}.\n\nTranscript:\n" +
      transcriptText;

    const upstream = await fetch(
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": c.env.GEMINI_API_KEY,
        },
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }],
          generationConfig: { responseMimeType: "application/json" },
        }),
      }
    );
    if (!upstream.ok) {
      return c.json({ error: "AI generation failed" }, 502);
    }
    const payload = (await upstream.json()) as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
    };
    const text = payload.candidates?.[0]?.content?.parts?.[0]?.text ?? "";
    let parsed: { title?: unknown; summary?: unknown; chapters?: unknown };
    try {
      parsed = JSON.parse(text);
    } catch {
      return c.json({ error: "AI returned malformed output" }, 502);
    }

    const title = typeof parsed.title === "string" ? parsed.title.slice(0, 80) : null;
    const summary =
      typeof parsed.summary === "string" ? parsed.summary.slice(0, 600) : null;
    const chapters = Array.isArray(parsed.chapters)
      ? (parsed.chapters as Array<{ start?: unknown; label?: unknown }>)
          .flatMap((ch) =>
            typeof ch.start === "number" && typeof ch.label === "string"
              ? [{ start: Math.max(0, ch.start), label: ch.label.slice(0, 60) }]
              : []
          )
          .slice(0, 12)
      : [];

    await setAISummary(c.env.DB, doc.videoId, {
      title,
      summary,
      chaptersJson: chapters.length > 0 ? JSON.stringify(chapters) : null,
      source: "gemini",
    });
    await caches.default.delete(
      new Request(`https://meta.internal/video/${doc.videoId}`)
    );
    return c.json({ title, summary, chapters });
  }
);

// ---------------------------------------------------------------------------
// Custom domains (Pro-gated)
// ---------------------------------------------------------------------------

const DOMAIN_RE =
  /^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$/;

/**
 * Custom share domains — Cloudflare for SaaS.
 *
 * Adding a domain does three things: records it, registers it as a custom
 * hostname on our zone (so Cloudflare routes it and issues its certificate),
 * and hands back the CNAME target. "Verify" checks our own CNAME lookup AND
 * refreshes Cloudflare's hostname + certificate status; a domain only routes
 * once both are active (`domainIsLive`). Removing a domain deletes the custom
 * hostname so the certificate is not left behind.
 */

hubRoutes.get("/domains", requireAuth, requireEntitlement(), async (c) => {
  const features = await featuresForTier(c.env.DB, c.get("entitlement").tier, c.get("entitlement").planName);
  return c.json({
    enabled: features.customDomain,
    cnameTarget: cnameTarget(c.env),
    provisioning: saasConfigured(c.env) ? "cloudflare" : "not_configured",
    domains: (await listDomains(c.env.DB, c.get("user").uid)).map(publicDomain),
  });
});

const DomainBodySchema = z.object({
  domain: z
    .string({ error: "domain is required" })
    .trim()
    .toLowerCase()
    .max(253, { error: "Domain is too long" })
    .regex(DOMAIN_RE, { error: "Enter a valid domain, e.g. share.yourcompany.com" }),
});

hubRoutes.post("/domains", requireAuth, requireEntitlement(), async (c) => {
  const features = await featuresForTier(c.env.DB, c.get("entitlement").tier, c.get("entitlement").planName);
  if (!features.customDomain) {
    return c.json({ error: "Custom domains require CaptureCat Pro" }, 402);
  }
  const parsed = await parseJsonBody(c.req, DomainBodySchema, { emptyOnInvalidJson: true });
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const { domain } = parsed.data;
  if (domain === "capturecat.so" || domain.endsWith(".capturecat.so")) {
    return c.json({ error: "That domain is reserved" }, 400);
  }
  const uid = c.get("user").uid;
  const existing = await listDomains(c.env.DB, uid);
  if (existing.length >= MAX_DOMAINS_PER_USER) return c.json({ error: "Domain limit reached" }, 400);
  // A claim is only a reservation until DNS verification: drop stale
  // unverified claims so squatting a domain someone else owns lapses in a
  // day instead of blocking the real owner forever.
  await c.env.DB.prepare(
    "DELETE FROM custom_domains WHERE domain = ? AND verified = 0 AND created_at < ?"
  ).bind(domain, new Date(Date.now() - 24 * 3600 * 1000).toISOString()).run();
  if (!(await insertDomain(c.env.DB, domain, uid))) {
    return c.json({ error: "That domain is already in use" }, 409);
  }

  // Register with Cloudflare now so the certificate is issued the moment the
  // customer's CNAME lands. A failure here is reported, not hidden: the row
  // stays, and Verify retries the registration.
  let provisioning: "cloudflare" | "not_configured" | "error" = "not_configured";
  let hostname: CustomHostname | null = null;
  if (saasConfigured(c.env)) {
    try {
      hostname = await createCustomHostname(c.env, domain);
      await setDomainCloudflareState(c.env.DB, domain, {
        cfHostnameId: hostname.id,
        cfStatus: hostname.status,
        cfSslStatus: hostname.sslStatus,
      });
      provisioning = "cloudflare";
    } catch (err) {
      console.error("domains: Cloudflare custom hostname create failed", err);
      provisioning = "error";
    }
  } else {
    console.error("domains: CF_ZONE_ID / CF_SAAS_API_TOKEN not set — domain recorded but cannot go live");
  }

  const record = await getDomain(c.env.DB, domain);
  return c.json({
    ...(record ? publicDomain(record) : { domain, verified: false, live: false }),
    cnameTarget: cnameTarget(c.env),
    provisioning,
    ownershipVerification: hostname?.ownershipVerification ?? null,
  });
});

/** DNS check via Cloudflare's DoH resolver (the domain must CNAME, or
 *  flatten, to our CNAME target) plus a refresh of Cloudflare's own view of
 *  the hostname. */
hubRoutes.post("/domains/:domain/verify", requireAuth, requireEntitlement(), async (c) => {
  const features = await featuresForTier(c.env.DB, c.get("entitlement").tier, c.get("entitlement").planName);
  if (!features.customDomain) {
    return c.json({ error: "Custom domains require CaptureCat Pro" }, 402);
  }
  const uid = c.get("user").uid;
  const domain = c.req.param("domain").toLowerCase();
  const record = (await listDomains(c.env.DB, uid)).find((d) => d.domain === domain);
  if (!record) return c.json({ error: "Domain not found" }, 404);

  const target = cnameTarget(c.env);
  const cnames = await lookupCnames(domain);
  const verified = cnames.some((t) => t === target || t === "capturecat.so" || t.endsWith(`.capturecat.so`));
  await setDomainVerified(c.env.DB, domain, verified);

  // Cloudflare's side: register if the add failed earlier, then read status.
  let hostname: CustomHostname | null = null;
  let provisioning: "cloudflare" | "not_configured" | "error" = "not_configured";
  if (saasConfigured(c.env)) {
    try {
      hostname = record.cfHostnameId
        ? await getCustomHostname(c.env, record.cfHostnameId)
        : null;
      if (!hostname) hostname = await createCustomHostname(c.env, domain);
      await setDomainCloudflareState(c.env.DB, domain, {
        cfHostnameId: hostname.id,
        cfStatus: hostname.status,
        cfSslStatus: hostname.sslStatus,
      });
      provisioning = "cloudflare";
    } catch (err) {
      console.error("domains: Cloudflare status refresh failed", err);
      provisioning = "error";
    }
  }

  const fresh = await getDomain(c.env.DB, domain);
  // The resolve endpoint is edge-cached; a domain that just went live (or
  // just lost verification) must not wait five minutes.
  await caches.default
    .delete(new Request(`https://domains.internal/resolve/${encodeURIComponent(domain)}`))
    .catch(() => {});
  return c.json({
    ...(fresh ? publicDomain(fresh) : { domain, verified, live: false }),
    found: cnames,
    expected: target,
    provisioning,
    ownershipVerification: hostname?.ownershipVerification ?? null,
    verificationErrors: hostname?.verificationErrors ?? [],
  });
});

hubRoutes.delete("/domains/:domain", requireAuth, async (c) => {
  const uid = c.get("user").uid;
  const domain = c.req.param("domain").toLowerCase();
  const record = (await listDomains(c.env.DB, uid)).find((d) => d.domain === domain);
  if (record?.cfHostnameId && saasConfigured(c.env)) {
    try {
      await deleteCustomHostname(c.env, record.cfHostnameId);
    } catch (err) {
      // Never strand the user with a domain they cannot remove; the
      // orphaned hostname is visible in the Cloudflare dashboard.
      console.error("domains: Cloudflare custom hostname delete failed", err);
    }
  }
  await deleteDomain(c.env.DB, domain, uid);
  await caches.default
    .delete(new Request(`https://domains.internal/resolve/${encodeURIComponent(domain)}`))
    .catch(() => {});
  return c.json({ ok: true });
});

/** Public resolve for the web Worker's host routing. A host is "found" only
 *  when it is LIVE (DNS + Cloudflare hostname + certificate) AND its owner's
 *  plan still includes custom domains — a cancelled Pro must not keep a
 *  branded share host. Edge-cached 5 min per colo; verify/delete purge it. */
hubRoutes.get("/domains/resolve", async (c) => {
  const host = (c.req.query("host") ?? "").toLowerCase();
  if (!DOMAIN_RE.test(host)) return c.json({ found: false });
  const cacheKey = new Request(`https://domains.internal/resolve/${encodeURIComponent(host)}`);
  const hit = await caches.default.match(cacheKey).catch(() => undefined);
  if (hit) return hit;
  const record = await resolveDomain(c.env.DB, host);
  let found = record !== null && domainIsLive(record);
  if (found && record) {
    found = (await planForUser(c.env, record.uid)).features.customDomain;
  }
  const res = c.json({ found }, 200, { "Cache-Control": "public, s-maxage=300" });
  await caches.default.put(cacheKey, res.clone()).catch(() => {});
  return res;
});

const MAX_DOMAINS_PER_USER = 3;

function publicDomain(d: CustomDomain) {
  return {
    domain: d.domain,
    verified: d.verified,
    live: domainIsLive(d),
    cfStatus: d.cfStatus,
    cfSslStatus: d.cfSslStatus,
    createdAt: d.createdAt,
  };
}

async function lookupCnames(domain: string): Promise<string[]> {
  try {
    const resp = await fetch(
      `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(domain)}&type=CNAME`,
      { headers: { Accept: "application/dns-json" } }
    );
    const dns = (await resp.json().catch(() => ({}))) as {
      Answer?: Array<{ type: number; data: string }>;
    };
    return (dns.Answer ?? [])
      .filter((a) => a.type === 5)
      .map((a) => a.data.replace(/\.$/, "").toLowerCase());
  } catch {
    return [];
  }
}
