/**
 * Parameter validation + SSRF guard for /api/screenshot/take.
 *
 * PURE module — no Hono, no bindings — so the whole truth table is unit
 * testable in plain vitest. Parameter names follow screenshotone.com's /take
 * where sensible (url, viewport_width, full_page, block_cookie_banners, …) so
 * existing client snippets port over with a base-URL change.
 */

/** Device presets — the same three profiles the desktop app's web capture
 *  uses: 1440 / 834 / 390 widths with scale 2 / 2 / 3 and matching UAs. */
export const DEVICE_PRESETS = {
  desktop: {
    width: 1440,
    height: 900,
    deviceScaleFactor: 2,
    isMobile: false,
    hasTouch: false,
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
  },
  tablet: {
    width: 834,
    height: 1194,
    deviceScaleFactor: 2,
    isMobile: true,
    hasTouch: true,
    userAgent:
      "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
  },
  mobile: {
    width: 390,
    height: 844,
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true,
    userAgent:
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
  },
} as const;

export type DevicePreset = keyof typeof DEVICE_PRESETS;

export type ImageFormat = "png" | "jpeg" | "webp";

/** Validated, defaulted options — the ONLY shape the renderer ever sees. */
export interface ScreenshotParams {
  url: string;
  viewportWidth: number;
  viewportHeight: number;
  deviceScaleFactor: number;
  isMobile: boolean;
  hasTouch: boolean;
  userAgent: string | null;
  fullPage: boolean;
  /** Cap the captured page height at N × viewportHeight (1–10). Only
   *  meaningful with fullPage=true; null = uncapped. The desktop app's
   *  "Full ×4" height mode sends 4. */
  maxHeightMultiple: number | null;
  format: ImageFormat;
  /** 1–100, jpeg/webp only; ignored for png. */
  quality: number | null;
  /** Extra settle time after load, ms (param is seconds, 0–10). */
  delayMs: number;
  darkMode: boolean;
  reducedMotion: boolean;
  blockCookieBanners: boolean;
  blockChats: boolean;
  /** User-supplied selectors to hide, already split + trimmed. */
  hideSelectors: string[];
  /** Best-effort click after load, or null. */
  clickSelector: string | null;
  /** Navigation timeout, ms (param is seconds, 1–30). */
  timeoutMs: number;
  /** store=true → persist to R2 and answer JSON with a URL. */
  store: boolean;
}

export interface ParamError {
  code: string;
  message: string;
}

export type ParamResult =
  | { ok: true; params: ScreenshotParams }
  | { ok: false; error: ParamError };

const err = (code: string, message: string): ParamResult => ({ ok: false, error: { code, message } });

// ---------------------------------------------------------------------------
// SSRF guard
// ---------------------------------------------------------------------------
// The renderer fetches whatever URL we hand it from Cloudflare's network, so
// this endpoint is a proxy by construction. What we CAN kill at this layer:
// non-http schemes, localhost in all spellings, literal IPs in every private/
// reserved range (WHATWG URL parsing canonicalizes decimal/hex/octal IPv4
// tricks like http://2130706433 into dotted form before we look at them), and
// an operator blocklist (SCREENSHOT_URL_BLOCKLIST) for internal hostnames.
// What we canNOT kill here: a public DNS name that resolves to a private IP
// (DNS rebinding) — that resolution happens inside Browser Rendering's own
// network, which is not our origin network, so the blast radius is
// Cloudflare-internal, not ours. Documented, not ignored.

const BLOCKED_HOSTNAMES = new Set(["localhost", "0.0.0.0", "[::]", "[::1]", "metadata.google.internal"]);
const BLOCKED_SUFFIXES = [".localhost", ".local", ".internal", ".home.arpa"];

function ipv4Octets(host: string): number[] | null {
  const m = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (!m) return null;
  const parts = m.slice(1).map(Number);
  return parts.every((n) => n <= 255) ? parts : null;
}

function isPrivateIPv4(host: string): boolean {
  const o = ipv4Octets(host);
  if (!o) return false;
  const [a, b] = o;
  return (
    a === 0 || // 0.0.0.0/8
    a === 10 || // 10/8
    a === 127 || // loopback
    (a === 100 && b >= 64 && b <= 127) || // 100.64/10 CGNAT
    (a === 169 && b === 254) || // link-local + cloud metadata (169.254.169.254)
    (a === 172 && b >= 16 && b <= 31) || // 172.16/12
    (a === 192 && b === 168) || // 192.168/16
    (a === 192 && b === 0) || // 192.0.0/24 + 192.0.2/24 doc range
    (a === 198 && (b === 18 || b === 19)) || // benchmark
    a >= 224 // multicast + reserved
  );
}

function isPrivateIPv6(host: string): boolean {
  // URL keeps IPv6 hosts bracketed; normalize + lowercase.
  const h = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (h === "::" || h === "::1") return true;
  if (h.startsWith("fe80:") || h.startsWith("fc") || h.startsWith("fd")) return true; // link-local, ULA
  if (h.startsWith("::ffff:")) {
    // IPv4-mapped — apply the v4 rules to the tail.
    const tail = h.slice(7);
    return ipv4Octets(tail) ? isPrivateIPv4(tail) : true; // hex-form mapped: reject
  }
  return false;
}

/**
 * Returns null when the URL is allowed, or a ParamError explaining why not.
 * `blocklist` is the comma-separated SCREENSHOT_URL_BLOCKLIST var: each entry
 * blocks the exact hostname and every subdomain of it.
 */
export function checkUrlAllowed(raw: string, blocklist?: string): ParamError | null {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return { code: "invalid_url", message: "url is not a valid absolute URL" };
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") {
    return { code: "invalid_url", message: "url must be http or https" };
  }
  if (u.username || u.password) {
    return { code: "invalid_url", message: "credentials in the url are not allowed" };
  }
  const host = u.hostname.toLowerCase();
  const blocked =
    BLOCKED_HOSTNAMES.has(host) ||
    BLOCKED_SUFFIXES.some((s) => host.endsWith(s)) ||
    isPrivateIPv4(host) ||
    (host.startsWith("[") || host.includes(":") ? isPrivateIPv6(host) : false);
  if (blocked) {
    return { code: "host_not_allowed", message: "url resolves to a private or internal address" };
  }
  for (const entry of (blocklist ?? "").split(",")) {
    const e = entry.trim().toLowerCase();
    if (!e) continue;
    if (host === e || host.endsWith("." + e)) {
      return { code: "host_not_allowed", message: "this host is not allowed" };
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/** Raw inputs: query params (GET) and JSON body (POST) both flatten to this. */
export type RawParams = Record<string, unknown>;

function asBool(v: unknown): boolean {
  if (typeof v === "boolean") return v;
  if (typeof v === "string") return v === "true" || v === "1";
  return false;
}

function asInt(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return Math.trunc(v);
  if (typeof v === "string" && v.trim() !== "") {
    const n = Number(v);
    return Number.isFinite(n) ? Math.trunc(n) : null;
  }
  return null;
}

function asStr(v: unknown): string | null {
  return typeof v === "string" && v.trim() !== "" ? v.trim() : null;
}

/** Reject selector strings that could escape the injected <style> block. */
function safeSelector(s: string): boolean {
  return s.length <= 200 && !/[{}<>]/.test(s);
}

export function parseScreenshotParams(raw: RawParams, blocklist?: string): ParamResult {
  const url = asStr(raw.url);
  if (!url) return err("missing_parameter", "url is required");
  const urlError = checkUrlAllowed(url, blocklist);
  if (urlError) return { ok: false, error: urlError };

  // Device preset seeds the profile; explicit viewport_* / device_scale_factor
  // override it — same precedence screenshotone uses.
  const deviceRaw = asStr(raw.device);
  if (deviceRaw && !(deviceRaw in DEVICE_PRESETS)) {
    return err("invalid_parameter", "device must be one of desktop, tablet, mobile");
  }
  const preset = DEVICE_PRESETS[(deviceRaw as DevicePreset) ?? "desktop"];

  const width = asInt(raw.viewport_width) ?? preset.width;
  const height = asInt(raw.viewport_height) ?? preset.height;
  if (width < 100 || width > 3840 || height < 100 || height > 3840) {
    return err("invalid_parameter", "viewport dimensions must be between 100 and 3840");
  }
  const dsf = asInt(raw.device_scale_factor) ?? preset.deviceScaleFactor;
  if (dsf < 1 || dsf > 3) {
    return err("invalid_parameter", "device_scale_factor must be between 1 and 3");
  }

  const format = (asStr(raw.format) ?? "png") as ImageFormat;
  if (!["png", "jpeg", "webp"].includes(format)) {
    return err("invalid_parameter", "format must be png, jpeg or webp");
  }
  let quality: number | null = null;
  if (raw.quality !== undefined && raw.quality !== "") {
    quality = asInt(raw.quality);
    if (quality === null || quality < 1 || quality > 100) {
      return err("invalid_parameter", "quality must be between 1 and 100");
    }
    if (format === "png") quality = null; // png has no quality axis
  }

  const delaySec = raw.delay === undefined ? 0 : asInt(raw.delay);
  if (delaySec === null || delaySec < 0 || delaySec > 10) {
    return err("invalid_parameter", "delay must be between 0 and 10 seconds");
  }
  const timeoutSec = raw.timeout === undefined ? 30 : asInt(raw.timeout);
  if (timeoutSec === null || timeoutSec < 1 || timeoutSec > 30) {
    return err("invalid_parameter", "timeout must be between 1 and 30 seconds");
  }

  const hideSelectors = (asStr(raw.hide_selectors) ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (hideSelectors.length > 20 || hideSelectors.some((s) => !safeSelector(s))) {
    return err("invalid_parameter", "hide_selectors: at most 20 selectors, none containing { } < >");
  }

  let maxHeightMultiple: number | null = null;
  if (raw.max_height_multiple !== undefined && raw.max_height_multiple !== "") {
    maxHeightMultiple = asInt(raw.max_height_multiple);
    if (maxHeightMultiple === null || maxHeightMultiple < 1 || maxHeightMultiple > 10) {
      return err("invalid_parameter", "max_height_multiple must be between 1 and 10");
    }
  }

  const clickSelector = asStr(raw.click_selector);
  if (clickSelector && !safeSelector(clickSelector)) {
    return err("invalid_parameter", "click_selector contains disallowed characters");
  }

  return {
    ok: true,
    params: {
      url,
      viewportWidth: width,
      viewportHeight: height,
      deviceScaleFactor: dsf,
      isMobile: preset.isMobile,
      hasTouch: preset.hasTouch,
      userAgent: deviceRaw ? preset.userAgent : null,
      fullPage: asBool(raw.full_page),
      maxHeightMultiple,
      format,
      quality,
      delayMs: delaySec * 1000,
      darkMode: asBool(raw.dark_mode),
      reducedMotion: asBool(raw.reduced_motion),
      blockCookieBanners: asBool(raw.block_cookie_banners),
      blockChats: asBool(raw.block_chats),
      hideSelectors,
      clickSelector,
      timeoutMs: timeoutSec * 1000,
      store: asBool(raw.store),
    },
  };
}

// ---------------------------------------------------------------------------
// Entitlement gate — pure decision so the route stays a thin pipe and the
// matrix (tier × feature × cap) is unit-testable with a mocked plan.
// ---------------------------------------------------------------------------

export interface GateInput {
  tier: "free" | "tester" | "paid";
  features: { screenshotApi?: boolean };
}

export type GateResult = { ok: true } | { ok: false; status: 403; error: ParamError };

export function screenshotGate(input: GateInput): GateResult {
  if (input.features.screenshotApi !== true) {
    return {
      ok: false,
      status: 403,
      error: {
        code: "upgrade_required",
        message: "The screenshot API requires a CaptureCat Pro plan.",
      },
    };
  }
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Session (desktop app / dashboard) policy — PRODUCT DECISION 2026-08-10:
//
// URL capture in the desktop app used to be a free, local WKWebView feature.
// Rendering moved to this Chromium endpoint, and a free local feature must not
// silently become pro-only — so SESSION-authenticated callers (the signed-in
// app or dashboard; there is no way to hold a session without an account) may
// render on EVERY plan, metered by a per-UTC-DAY allowance instead of the
// plan's monthly Screenshot-API quota. API-KEY callers are unchanged: the
// `screenshotApi` feature gate (pro-only) plus `maxScreenshotsPerMonth`.
// The daily counter shares the screenshot_usage table under an 8-digit
// YYYYMMDD key, which can never collide with the 6-digit monthly YYYYMM key.
// ---------------------------------------------------------------------------

/** Renders per UTC day for a session-authenticated caller, by tier. */
export function sessionDailyScreenshotCap(tier: "free" | "tester" | "paid"): number {
  switch (tier) {
    case "free":
      return 30;
    case "tester":
    case "paid":
      return 500;
  }
}
