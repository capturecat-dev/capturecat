/**
 * Rendering engine for /api/screenshot/take — Cloudflare Browser Rendering's
 * REST "quick action" /screenshot endpoint.
 *
 * WHY REST AND NOT THE `browser` WORKER BINDING: the REST surface is billed on
 * browser DURATION only ($0.09/browser-hour past the included 10 hrs/month on
 * Workers Paid), while the binding additionally bills $2 per concurrent
 * browser beyond 10 — for a bursty one-shot-screenshot workload REST is both
 * cheaper and simpler (no session pooling, Cloudflare closes the browser
 * itself). The engine hides behind `ScreenshotRenderer`, so a
 * `@cloudflare/puppeteer` binding engine can be swapped in later for
 * deep-interaction features without touching the route or the mapper.
 *
 * NOTE ON NAMING: Cloudflare has begun rebranding the product "Browser Run",
 * but as of 2026-08-10 the live REST base path is still
 * `/accounts/{account_id}/browser-rendering/…` (verified against the current
 * API reference; /browser-run/rest-api/* 404s). If a request starts failing
 * with 404s after a Cloudflare-side migration, check the path first.
 *
 * `buildRestBody` is PURE — the option→engine mapping is the part that has to
 * be provably right, so it is unit-tested in isolation; the fetch wrapper is
 * the only untestable sliver (live testing needs real credentials).
 */

import type { ScreenshotParams } from "./params";
import { buildHideCss } from "./hide-rules";

export interface RenderResult {
  bytes: ArrayBuffer;
  contentType: string;
}

export type RenderFailure = {
  code: "timeout" | "render_failed";
  message: string;
  status: 502 | 504;
};

export interface ScreenshotRenderer {
  render(params: ScreenshotParams): Promise<RenderResult | { error: RenderFailure }>;
}

export const CONTENT_TYPES: Record<ScreenshotParams["format"], string> = {
  png: "image/png",
  jpeg: "image/jpeg",
  webp: "image/webp",
};

/** JSON body for POST …/browser-rendering/screenshot. */
export function buildRestBody(p: ScreenshotParams): Record<string, unknown> {
  const scripts: string[] = [];

  // dark_mode / reduced_motion — BEST EFFORT on the REST engine: it exposes no
  // emulateMediaFeatures (confirmed against the current API schema), so we
  // patch window.matchMedia before app code queries it and set color-scheme.
  // Pure-CSS `@media (prefers-color-scheme: dark)` blocks are NOT retriggered
  // by this; a future puppeteer-binding engine would emulate them for real.
  //
  // PARITY with the macOS app (WebPageCapture): dark_mode on both sides is
  // strictly the site's OWN dark theme (product rule: never an invented
  // restyle — no inversion filters). The app additionally gets true CSS
  // media-query flips via NSAppearance; this engine only gets the matchMedia
  // patch above, so pure-CSS dark themes may not flip here. Known, accepted.
  if (p.darkMode || p.reducedMotion) {
    const overrides: string[] = [];
    if (p.darkMode) overrides.push("['prefers-color-scheme','dark']");
    if (p.reducedMotion) overrides.push("['prefers-reduced-motion','reduce']");
    scripts.push(
      `(() => { const o = new Map([${overrides.join(",")}]);` +
        ` const orig = window.matchMedia.bind(window);` +
        ` window.matchMedia = (q) => { for (const [k, v] of o) { if (q.includes(k)) {` +
        ` const m = q.includes(v); return { matches: m, media: q, addListener(){}, removeListener(){},` +
        ` addEventListener(){}, removeEventListener(){}, dispatchEvent(){ return false; }, onchange: null }; } }` +
        ` return orig(q); };` +
        (p.darkMode ? ` document.documentElement.style.colorScheme = 'dark';` : "") +
        ` })();`,
    );
  }

  // click_selector — the REST engine has no click primitive, so this is an
  // injected click after load (guarded; a missing element is a no-op). Users
  // needing multi-step interaction belong on a future binding engine.
  if (p.clickSelector) {
    scripts.push(
      `try { document.querySelector(${JSON.stringify(p.clickSelector)})?.click(); } catch (e) {}`,
    );
  }

  const hideCss = buildHideCss({
    cookieBanners: p.blockCookieBanners,
    chats: p.blockChats,
    extraSelectors: p.hideSelectors,
    host: (() => {
      try {
        return new URL(p.url).hostname;
      } catch {
        return null;
      }
    })(),
  });

  const body: Record<string, unknown> = {
    url: p.url,
    viewport: {
      width: p.viewportWidth,
      height: p.viewportHeight,
      deviceScaleFactor: p.deviceScaleFactor,
      isMobile: p.isMobile,
      hasTouch: p.hasTouch,
    },
    gotoOptions: {
      waitUntil: "networkidle2",
      timeout: p.timeoutMs,
    },
    screenshotOptions: {
      type: p.format,
      fullPage: p.fullPage,
      ...(p.quality !== null ? { quality: p.quality } : {}),
    },
  };
  if (p.userAgent) body.userAgent = p.userAgent;
  if (hideCss) body.addStyleTag = [{ content: hideCss }];
  if (scripts.length > 0) body.addScriptTag = scripts.map((content) => ({ content }));
  if (p.delayMs > 0) body.waitForTimeout = p.delayMs;
  return body;
}

// ---------------------------------------------------------------------------
// max_height_multiple — cap a full-page capture at N × the viewport height,
// with min(content, cap) semantics (the desktop app's "Full ×4" mode under
// WKWebView measured scrollHeight and capped it; a short page keeps its
// natural height, never blank padding).
//
// WHY MEASURE-THEN-CLIP: an in-page CSS clamp (max-height + overflow:hidden
// on the root) was tried first and is NOT reliable — Chromium's full-page
// size comes from the root's scrollable-overflow rect, which overflow:hidden
// does not shrink (verified live: a 5029px page kept rendering 5029px with
// the clamp injected). The Worker also cannot crop PNG bytes (no image codec
// in workerd). So the renderer makes TWO REST calls for this mode only:
//   1. /scrape `html` with the identical viewport/UA/goto/style/script/delay
//      payload → the laid-out document height (identical payload matters:
//      hidden cookie banners change the height);
//   2. /screenshot with `clip` = min(measured, N × viewport_height), which
//      Chromium honors exactly (captureBeyondViewport renders past the fold).
// The extra browser session is paid only by Full×N captures; if the measure
// call fails, the clip falls back to the cap (worst case: blank tail, never
// a failed capture).
// ---------------------------------------------------------------------------

/** /scrape body: the /screenshot body minus screenshot-only keys, plus the
 *  `html` element query whose laid-out height is the document height. */
export function buildMeasureBody(p: ScreenshotParams): Record<string, unknown> {
  const body = buildRestBody(p);
  delete body.screenshotOptions;
  body.elements = [{ selector: "html" }];
  return body;
}

/** Clip height in CSS px: measured content clamped to [viewport, N×viewport].
 *  A failed measurement (null) falls back to the cap — worst case a blank
 *  tail, never a failed capture. Mirrors the WKWebView path's
 *  `min(measuredHeight(minimum: viewportHeight), viewportHeight * 4)`. */
export function cappedClipHeight(p: ScreenshotParams, measured: number | null): number {
  const cap = p.viewportHeight * (p.maxHeightMultiple ?? 1);
  if (measured === null || !Number.isFinite(measured) || measured <= 0) return cap;
  return Math.min(Math.max(Math.round(measured), p.viewportHeight), cap);
}

/** Pulls the `html` element's height out of a /scrape result envelope. */
export function measuredHeightFromScrape(json: unknown): number | null {
  const result = (json as { result?: Array<{ results?: Array<{ height?: unknown }> }> })?.result;
  const h = result?.[0]?.results?.[0]?.height;
  return typeof h === "number" && Number.isFinite(h) && h > 0 ? h : null;
}

/** Deterministic cache key for `store=true` R2 objects: same URL + same
 *  options → same object, so repeat calls overwrite instead of accreting. */
export async function cacheKey(p: ScreenshotParams): Promise<string> {
  const { store: _store, ...rest } = p;
  const canonical = JSON.stringify(rest, Object.keys(rest).sort());
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonical));
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 32);
}

export class RestRenderer implements ScreenshotRenderer {
  constructor(
    private accountId: string,
    private apiToken: string,
  ) {}

  async render(params: ScreenshotParams): Promise<RenderResult | { error: RenderFailure }> {
    const body = buildRestBody(params);

    // Full×N: measure first (see the block comment above buildMeasureBody),
    // then screenshot a clip of min(content, cap) instead of fullPage.
    if (params.fullPage && params.maxHeightMultiple !== null) {
      let measured: number | null = null;
      try {
        const res = await this.post("scrape", buildMeasureBody(params), params.timeoutMs);
        if (res.ok) measured = measuredHeightFromScrape(await res.json());
        else console.error("screenshot: measure call failed", res.status);
      } catch (e) {
        console.error("screenshot: measure call threw", e instanceof Error ? e.message : e);
      }
      const shot = body.screenshotOptions as Record<string, unknown>;
      delete shot.fullPage;
      shot.clip = {
        x: 0,
        y: 0,
        width: params.viewportWidth,
        height: cappedClipHeight(params, measured),
      };
      shot.captureBeyondViewport = true;
    }

    let res: Response;
    try {
      res = await this.post("screenshot", body, params.timeoutMs);
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      console.error("screenshot: browser-rendering fetch failed", message);
      return {
        error: message.includes("timed out") || message.includes("abort")
          ? { code: "timeout", message: "The page did not finish loading in time.", status: 504 }
          : { code: "render_failed", message: "The rendering service could not be reached.", status: 502 },
      };
    }

    if (!res.ok) {
      // Error bodies are JSON envelopes; never forward them verbatim (they
      // can carry account-level details). Log, map, move on.
      const text = await res.text().catch(() => "");
      console.error("screenshot: browser-rendering error", res.status, text.slice(0, 500));
      const timeout = res.status === 504 || text.includes("imeout");
      return {
        error: timeout
          ? { code: "timeout", message: "The page did not finish loading in time.", status: 504 }
          : { code: "render_failed", message: "The page could not be rendered.", status: 502 },
      };
    }

    return {
      bytes: await res.arrayBuffer(),
      contentType: res.headers.get("Content-Type") ?? CONTENT_TYPES[params.format],
    };
  }

  private post(action: "screenshot" | "scrape", body: Record<string, unknown>, timeoutMs: number): Promise<Response> {
    return fetch(
      `https://api.cloudflare.com/client/v4/accounts/${this.accountId}/browser-rendering/${action}`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.apiToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
        // Navigation timeout + render + margin; Cloudflare bills duration, so
        // a hung upstream must not run to the Worker's own limit.
        signal: AbortSignal.timeout(timeoutMs + 15_000),
      },
    );
  }
}
