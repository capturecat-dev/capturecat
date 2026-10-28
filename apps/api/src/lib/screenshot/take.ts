/**
 * One screenshot render, for an already-authenticated caller: the plan gate,
 * parameter parsing, the monthly quota, the render and the optional store.
 * Shared by /api/screenshot/take (routes/screenshot.ts, which owns the two
 * auth doors) and the MCP take_screenshot tool (src/mcp/), so an agent token
 * is held to exactly what an access key is: the `screenshotApi` plan flag and
 * the same monthly counter.
 *
 * Never throws for a refusal — every outcome is a value the caller maps onto
 * its own response shape. `quota` is present once the quota check has run,
 * so the route can keep reporting X-Screenshot-Quota-* exactly when it did.
 */

import type { ContentfulStatusCode } from "hono/utils/http-status";
import type { Env } from "../../types";
import { resolveEntitlement } from "../entitlement";
import { planForEntitlement } from "../plans";
import { checkUploadAllowance } from "../upload-policy";
import { recordStoredObject, storageUsageBytes } from "../db";
import { createPresignedDownloadUrl } from "../presign";
import { parseScreenshotParams, screenshotGate, type ImageFormat, type RawParams } from "./params";
import { consumeQuota, type QuotaResult } from "./quota";
import { RestRenderer, cacheKey, CONTENT_TYPES } from "./renderer";

export interface ScreenshotCaller {
  uid: string;
  claims: { tester: boolean; blocked: boolean };
  /** Which plan flag opens the door (lib/screenshot/params.ts screenshotGate):
   *  "session" = the signed-in web app (`webCapture`); "key" = any
   *  programmatic credential, access key or agent token (`screenshotApi`). */
  door: "session" | "key";
}

export interface StoredScreenshotResult {
  cache_key: string;
  key: string;
  url: string;
  expires_in: number;
  format: ImageFormat;
}

export type TakeOutcome =
  | {
      ok: false;
      status: ContentfulStatusCode;
      error: { code: string; message: string };
      quota?: QuotaResult;
    }
  | { ok: true; kind: "image"; bytes: ArrayBuffer; contentType: string; format: ImageFormat; quota: QuotaResult }
  | { ok: true; kind: "stored"; stored: StoredScreenshotResult; quota: QuotaResult };

const refuse = (status: ContentfulStatusCode, code: string, message: string, quota?: QuotaResult): TakeOutcome => ({
  ok: false,
  status,
  error: { code, message },
  ...(quota ? { quota } : {}),
});

export async function takeScreenshot(env: Env, caller: ScreenshotCaller, raw: RawParams): Promise<TakeOutcome> {
  // Tier + subscribed plan (features AND limits in one lookup).
  const ent = await resolveEntitlement(env.DB, caller.uid, caller.claims);
  if (ent === "blocked") return refuse(403, "account_blocked", "This account is blocked.");
  const plan = await planForEntitlement(env.DB, ent);
  // POLICY (2026-09-03, supersedes 2026-08-10): both doors are plan-gated.
  // The old "sessions render on every plan" rule contradicted the pricing
  // page (web capture is listed under Pro) and the plan table (free has
  // webCapture:false), and was bypassable by forging the Origin header.
  const gate = screenshotGate({ tier: ent.tier, features: plan.features, door: caller.door });
  if (!gate.ok) return { ok: false, status: gate.status, error: gate.error };

  // `engine` — chromium is the only implemented engine. A "kitesurf" beta
  // engine was floated but does not exist in Cloudflare's current REST docs;
  // refuse unknown values loudly rather than silently rendering on chromium.
  const engine = typeof raw.engine === "string" && raw.engine.trim() !== "" ? raw.engine.trim() : "chromium";
  if (engine !== "chromium") {
    return refuse(400, "engine_unavailable", `Unknown engine "${engine}". Supported: chromium.`);
  }

  const parsed = parseScreenshotParams(raw, env.SCREENSHOT_URL_BLOCKLIST);
  if (!parsed.ok) return { ok: false, status: 400, error: parsed.error };
  const params = parsed.params;

  if (!env.CF_ACCOUNT_ID || !env.BROWSER_RENDERING_TOKEN) {
    return refuse(503, "not_configured", "Screenshot rendering is not configured.");
  }

  // store=true keeps bytes: that needs the imageUpload flag AND room in the
  // storage cap, decided BEFORE rendering so a refused request bills nothing.
  if (params.store && !plan.features.imageUpload) {
    return refuse(403, "upgrade_required", "Storing screenshots requires a plan with image uploads.");
  }

  // Quota BEFORE rendering: refused requests consume nothing, and the SQL's
  // conditional upsert means a race can never spend the last unit twice.
  // One monthly counter for every door, from the plan row.
  const cap = plan.limits.maxScreenshotsPerMonth;
  const quota = await consumeQuota(env.DB, caller.uid, cap, new Date(), "month").catch((e) => {
    // Fail closed — a broken meter must not become unmetered renders.
    console.error("screenshot: quota check failed", e instanceof Error ? e.message : e);
    return { allowed: false, used: 0, cap };
  });
  if (!quota.allowed) {
    return refuse(
      429,
      "quota_exceeded",
      quota.cap <= 0
        ? "Your plan includes no screenshot renders."
        : `Monthly screenshot quota (${quota.cap}) exhausted. It resets on the 1st (UTC).`,
      quota,
    );
  }

  const renderer = new RestRenderer(env.CF_ACCOUNT_ID, env.BROWSER_RENDERING_TOKEN);
  const result = await renderer.render(params);
  if ("error" in result) {
    return refuse(result.error.status, result.error.code, result.error.message, quota);
  }

  if (params.store) {
    // Persist under a deterministic options-hash key (repeat call = overwrite,
    // not accretion) and answer JSON with a presigned URL — the same S3-API
    // serving convention upload.ts uses, so no new public route exists.
    const hash = await cacheKey(params);
    const key = `screenshots/${caller.uid}/${hash}.${params.format}`;
    // The rendered size is known now: hold it to the same storage cap as a
    // video, and record it so the cap sees it next time.
    const usedBytes = await storageUsageBytes(env.DB, caller.uid);
    const verdict = checkUploadAllowance(plan, { fileSizeBytes: result.bytes.byteLength, usedBytes });
    if (!verdict.ok) return refuse(verdict.status, verdict.body.code, verdict.body.error, quota);
    await env.R2.put(key, result.bytes, {
      httpMetadata: { contentType: CONTENT_TYPES[params.format] },
    });
    await recordStoredObject(env.DB, {
      r2Key: key,
      uid: caller.uid,
      kind: "screenshot",
      bytes: result.bytes.byteLength,
    });
    const url = await createPresignedDownloadUrl({
      endpoint: env.R2_ENDPOINT,
      accessKeyId: env.R2_ACCESS_KEY_ID,
      secretAccessKey: env.R2_SECRET_ACCESS_KEY,
      bucket: "capturecat",
      key,
      expiresIn: 3600,
    });
    return {
      ok: true,
      kind: "stored",
      stored: { cache_key: hash, key, url, expires_in: 3600, format: params.format },
      quota,
    };
  }

  return { ok: true, kind: "image", bytes: result.bytes, contentType: result.contentType, format: params.format, quota };
}
