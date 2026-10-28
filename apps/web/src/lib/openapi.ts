/**
 * OpenAPI 3.1 description of CaptureCat's public developer API, for API
 * clients and LLM agents (function calling). HAND-MAINTAINED, not generated —
 * every path, parameter, range, default, status and error code below was read
 * off these files, and this one must change in the same commit as they do:
 *
 *   apps/api/src/index.ts                         mount point (/api), /api/health,
 *                                                 per-IP rate limits for /api/screenshot/*
 *   apps/api/src/routes/screenshot.ts             /api/screenshot/* — auth doors, error codes,
 *                                                 store=true JSON, key + stored-object management
 *   apps/api/src/lib/screenshot/params.ts         every /take option: names, ranges, defaults,
 *                                                 SSRF refusals, the plan gate
 *   apps/api/src/lib/screenshot/keys.ts           access-key token format
 *   apps/api/src/lib/screenshot/quota.ts          monthly render quota
 *   apps/api/src/lib/screenshot/renderer.ts       content types, 502/504 mapping, cache_key
 *   apps/api/src/lib/upload-policy.ts             store=true storage-cap refusals (402/413)
 *   apps/api/src/middleware/rate-limit.ts         429 body + Retry-After / X-RateLimit-* headers
 *   apps/api/src/routes/releases.ts               /api/releases/*
 *   apps/macos/scripts/publish_release.sh         the release JSON those routes pass through
 *   apps/web/src/routes/api/oembed.ts             https://capturecat.so/api/oembed (web Worker)
 *
 * openapi.test.ts checks the document's SHAPE (unique operationIds, resolvable
 * $refs, described parameters). Only re-reading the routes checks its TRUTH.
 */

/** One /api/screenshot/take option. GET sends these as query parameters and
 *  POST as JSON body keys — the route flattens both into the same RawParams
 *  before parseScreenshotParams, so both are built from this one table. */
interface TakeOption {
  required?: boolean;
  description: string;
  schema: Record<string, unknown>;
}

const BOOLEAN_INPUT =
  "Pass `true` (the strings `\"true\"` and `\"1\"` also count); any other value, or leaving it out, means false.";
const INTEGER_INPUT = "Integer; numeric strings are accepted and fractions are truncated.";

const TAKE_OPTIONS: Record<string, TakeOption> = {
  url: {
    required: true,
    description:
      "Absolute http(s) URL of the page to render. Refused with `invalid_url` when it does not parse, is not http/https, or carries credentials (`user:pass@`). Refused with `host_not_allowed` for localhost, `*.localhost`, `*.local`, `*.internal`, `*.home.arpa`, `metadata.google.internal`, private/loopback/link-local/CGNAT/reserved IPv4 literals (including cloud metadata 169.254.169.254), loopback, link-local, unique-local and IPv4-mapped-private IPv6 literals, and hosts on the operator's blocklist. A public hostname that resolves to a private address is not detected here. Missing or blank: `missing_parameter`.",
    schema: { type: "string", format: "uri" },
  },
  device: {
    description:
      "Device preset that seeds the viewport. `desktop`: 1440×900 at scale 2 with a desktop Chrome user agent. `tablet`: 834×1194 at scale 2, mobile + touch emulation, iPad Safari user agent. `mobile`: 390×844 at scale 3, mobile + touch emulation, iPhone Safari user agent. When omitted, the desktop viewport and scale are used and the renderer keeps its own default user agent. `viewport_width`, `viewport_height` and `device_scale_factor` override the preset. Any other value: `invalid_parameter`.",
    schema: { type: "string", enum: ["desktop", "tablet", "mobile"] },
  },
  viewport_width: {
    description: `Viewport width in CSS pixels, 100–3840. Defaults to the device preset's width (1440 when \`device\` is omitted). ${INTEGER_INPUT} A non-numeric value is ignored (the preset width is used).`,
    schema: { type: "integer", minimum: 100, maximum: 3840 },
  },
  viewport_height: {
    description: `Viewport height in CSS pixels, 100–3840. Defaults to the device preset's height (900 when \`device\` is omitted). ${INTEGER_INPUT} A non-numeric value is ignored (the preset height is used).`,
    schema: { type: "integer", minimum: 100, maximum: 3840 },
  },
  device_scale_factor: {
    description: `Device pixel ratio, 1–3 (the image is this many times the viewport size). Defaults to the device preset's scale (2 when \`device\` is omitted). ${INTEGER_INPUT} A non-numeric value is ignored (the preset scale is used).`,
    schema: { type: "integer", minimum: 1, maximum: 3 },
  },
  full_page: {
    description: `Capture the whole scrollable page instead of only the viewport. ${BOOLEAN_INPUT}`,
    schema: { type: "boolean", default: false },
  },
  max_height_multiple: {
    description: `Only used with \`full_page=true\`: caps the captured height at N × \`viewport_height\`. The capture is the page's measured height clamped between one viewport and that cap; if the height cannot be measured, exactly N × \`viewport_height\` is captured. Omit (or send an empty value) for an uncapped full-page capture. ${INTEGER_INPUT}`,
    schema: { type: "integer", minimum: 1, maximum: 10 },
  },
  format: {
    description:
      "Image format. Decides the response `Content-Type` (`image/png`, `image/jpeg`, `image/webp`) and the stored object's extension. `jpg` is not accepted.",
    schema: { type: "string", enum: ["png", "jpeg", "webp"], default: "png" },
  },
  quality: {
    description: `Compression quality, 1–100, for \`jpeg\` and \`webp\`. Validated for every format but ignored for \`png\`. Omit (or send an empty value) for the renderer's default. ${INTEGER_INPUT}`,
    schema: { type: "integer", minimum: 1, maximum: 100 },
  },
  delay: {
    description: `Extra seconds to wait after the page has loaded before capturing, 0–10. ${INTEGER_INPUT}`,
    schema: { type: "integer", minimum: 0, maximum: 10, default: 0 },
  },
  timeout: {
    description: `Navigation timeout in seconds, 1–30. The page is loaded until the network is idle; a page that does not finish in time returns 504 \`timeout\`. ${INTEGER_INPUT}`,
    schema: { type: "integer", minimum: 1, maximum: 30, default: 30 },
  },
  dark_mode: {
    description: `Best effort: makes \`window.matchMedia('(prefers-color-scheme: dark)')\` report a match and sets \`color-scheme: dark\` on the root element. Pure-CSS \`@media (prefers-color-scheme: dark)\` rules are NOT re-triggered, so sites themed only in CSS may stay light. Never inverts colours. ${BOOLEAN_INPUT}`,
    schema: { type: "boolean", default: false },
  },
  reduced_motion: {
    description: `Best effort: makes \`window.matchMedia('(prefers-reduced-motion: reduce)')\` report a match. CSS media queries are not affected. ${BOOLEAN_INPUT}`,
    schema: { type: "boolean", default: false },
  },
  block_cookie_banners: {
    description: `Hide cookie-consent banners (the EasyList Cookie List plus curated selectors for OneTrust, Cookiebot, Didomi, Usercentrics, TrustArc and other consent managers) and restore page scrolling they lock. ${BOOLEAN_INPUT}`,
    schema: { type: "boolean", default: false },
  },
  block_chats: {
    description: `Hide common live-chat widgets (Intercom, Drift, Zendesk, Crisp, Tawk.to, HubSpot, LiveChat, Tidio, Freshchat). ${BOOLEAN_INPUT}`,
    schema: { type: "boolean", default: false },
  },
  hide_selectors: {
    description:
      "Comma-separated CSS selectors to hide (`display: none`). At most 20 selectors, each at most 200 characters, none containing `{`, `}`, `<` or `>` (otherwise `invalid_parameter`). Must be a single string, also in a JSON body (an array is ignored). Because the list is split on commas, a selector that itself contains a comma cannot be expressed.",
    schema: { type: "string" },
  },
  click_selector: {
    description:
      "CSS selector of one element to click after the page loads, via an injected script (best effort: a missing element is ignored). At most 200 characters, none of `{`, `}`, `<`, `>` (otherwise `invalid_parameter`).",
    schema: { type: "string", maxLength: 200 },
  },
  store: {
    description: `Save the image to your CaptureCat storage and answer JSON (\`TakeScreenshotStoredResult\`) with a presigned download URL valid for 3600 seconds, instead of the image bytes. Requires a plan with image uploads (403 \`upgrade_required\`) and room under the plan's storage cap (402/413). The same URL with the same options maps to the same stored object, so repeating a call overwrites rather than adds. ${BOOLEAN_INPUT}`,
    schema: { type: "boolean", default: false },
  },
  engine: {
    description:
      "Rendering engine. Only `chromium` exists; any other non-blank value returns 400 `engine_unavailable`.",
    schema: { type: "string", enum: ["chromium"], default: "chromium" },
  },
};

const takeQueryParameters = Object.entries(TAKE_OPTIONS).map(([name, option]) => ({
  name,
  in: "query",
  required: option.required === true,
  description: option.description,
  schema: option.schema,
}));

const takeBodyProperties: Record<string, Record<string, unknown>> = {
  ...Object.fromEntries(
    Object.entries(TAKE_OPTIONS).map(([name, option]) => [
      name,
      { ...option.schema, description: option.description },
    ]),
  ),
  access_key: {
    type: "string",
    description:
      "Access key (`cc_live_…`) for clients that cannot set headers. The `X-Access-Key` header wins over the `access_key` query parameter, which wins over this field.",
  },
};

const ref = (name: string) => ({ $ref: `#/components/schemas/${name}` });
const json = (schemaName: string) => ({ "application/json": { schema: ref(schemaName) } });

/** Headers every /api/screenshot/* response carries once it passed the per-IP limiter. */
const rateLimitHeaders = {
  "X-RateLimit-Limit": { $ref: "#/components/headers/XRateLimitLimit" },
  "X-RateLimit-Remaining": { $ref: "#/components/headers/XRateLimitRemaining" },
};

const quotaHeaders = {
  "X-Screenshot-Quota-Limit": { $ref: "#/components/headers/XScreenshotQuotaLimit" },
  "X-Screenshot-Quota-Remaining": { $ref: "#/components/headers/XScreenshotQuotaRemaining" },
};

const SCREENSHOT_IMAGE = { type: "string", format: "binary" } as const;

/** The /take responses are identical for GET and POST, except POST can also
 *  refuse a body that is not a JSON object (400 invalid_request). */
function takeResponses(method: "get" | "post") {
  return {
    "200": {
      description:
        "The rendered image (`Content-Type` follows `format`), or — when `store=true` — JSON describing the stored object and a presigned download URL.",
      headers: {
        ...rateLimitHeaders,
        ...quotaHeaders,
        "Cache-Control": {
          description: "`no-store` on image responses.",
          schema: { type: "string" },
        },
      },
      content: {
        "image/png": { schema: { ...SCREENSHOT_IMAGE, description: "PNG image (format=png, the default)." } },
        "image/jpeg": { schema: { ...SCREENSHOT_IMAGE, description: "JPEG image (format=jpeg)." } },
        "image/webp": { schema: { ...SCREENSHOT_IMAGE, description: "WebP image (format=webp)." } },
        "application/json": { schema: ref("TakeScreenshotStoredResult") },
      },
    },
    "400": {
      description:
        (method === "post"
          ? "`invalid_request` (the body is not JSON, or not a JSON object — checked before authentication), "
          : "") +
        "`engine_unavailable`, `missing_parameter`, `invalid_url`, `host_not_allowed` or `invalid_parameter`.",
      content: json("ScreenshotError"),
    },
    "401": {
      description:
        "`unauthorized`: no valid access key or session. A supplied access key that is malformed, unknown or revoked is refused here; there is no fallback to a session.",
      content: json("ScreenshotError"),
    },
    "402": {
      description:
        "store=true only, after rendering: `cloud_share_required` (the plan does not include cloud sharing) or `no_storage_allowance` (the plan's storage or per-file cap is zero).",
      content: json("ScreenshotError"),
    },
    "403": {
      description:
        "`forbidden` (a session caller that is not a POST from the CaptureCat web app — every session request to GET), `account_blocked`, or `upgrade_required` (the plan lacks the screenshot API for key callers / web capture for session callers, or `store=true` without image uploads).",
      content: json("ScreenshotError"),
    },
    "413": {
      description:
        "store=true only, after rendering: `file_too_large` (the image exceeds the plan's per-file size limit) or `storage_limit_reached` (it would exceed the plan's total storage cap).",
      content: json("ScreenshotError"),
    },
    "429": {
      description:
        "Either `quota_exceeded` (the plan's monthly render quota is used up, or the plan includes none; resets on the 1st, UTC — carries the X-Screenshot-Quota-* headers) or the per-IP rate limit (`{\"error\":\"Too many requests\"}` with `Retry-After`).",
      headers: {
        ...quotaHeaders,
        "Retry-After": { $ref: "#/components/headers/RetryAfter" },
      },
      content: {
        "application/json": {
          schema: { oneOf: [ref("ScreenshotError"), ref("RateLimitError")] },
        },
      },
    },
    "502": {
      description: "`render_failed`: the page could not be rendered, or the rendering service could not be reached.",
      content: json("ScreenshotError"),
    },
    "503": {
      description: "`not_configured`: screenshot rendering is not configured on this deployment.",
      content: json("ScreenshotError"),
    },
    "504": {
      description: "`timeout`: the page did not finish loading in time.",
      content: json("ScreenshotError"),
    },
  };
}

const TAKE_COMMON_DESCRIPTION =
  "Requires a plan that includes the screenshot API (CaptureCat Pro; otherwise 403 `upgrade_required`). Each request that passes authentication, the plan check and validation takes one render from the plan's monthly quota BEFORE rendering: requests refused earlier consume nothing, but a failed render (502/504) or a refused store (402/413) does not give the unit back. The quota resets on the 1st of each month (UTC); `X-Screenshot-Quota-Limit` / `X-Screenshot-Quota-Remaining` report it. Unknown parameters (for example a `response_type` that other screenshot APIs accept) are ignored. Per-IP rate limit: 10 requests per fixed 60-second window, shared with /api/screenshot/stored.";

export const OPENAPI_DOCUMENT = {
  openapi: "3.1.0",
  info: {
    title: "CaptureCat API",
    version: "1.0.0",
    description:
      "Public developer API of CaptureCat, the macOS screen recorder with a web editor and share links. Use it to:\n\n" +
      "- **Render screenshots of public web pages** (`/api/screenshot/take`, a paid Screenshot API with conventional snake_case parameter names), and manage its access keys and stored screenshots.\n" +
      "- **Find and download CaptureCat for Mac** (`/api/releases/*`).\n" +
      "- **Check service health** (`/api/health`).\n" +
      "- **Embed a CaptureCat share link** via oEmbed (`/api/oembed`, served from https://capturecat.so).\n\n" +
      "Documentation: https://capturecat.so/docs — machine-readable index for LLMs: https://capturecat.so/llms.txt\n\n" +
      "**Authentication.** Screenshot renders take an access key (`cc_live_…`) in the `X-Access-Key` header or the `access_key` query parameter. Keys are minted, listed and revoked with a signed-in CaptureCat session (Better Auth, `Authorization: Bearer <session token>` as the Mac app sends it); an access key can never manage keys. Release, health and oEmbed endpoints are public.\n\n" +
      "**Errors.** Screenshot endpoints answer `{ \"error\": { \"code\": \"…\", \"message\": \"…\" } }`; branch on `code`. Release and oEmbed endpoints, the per-IP rate limiter (429) and unknown routes (404) answer `{ \"error\": \"<message>\" }`.\n\n" +
      "**Rate limits** (per client IP, fixed 60-second windows): `/api/screenshot/take` and `/api/screenshot/stored*` share 10 requests; `/api/screenshot/keys*` allows 30. Release, health and oEmbed endpoints have no application-level rate limit.",
    contact: {
      name: "CaptureCat",
      email: "contact@capturecat.so",
      url: "https://capturecat.so",
    },
  },
  externalDocs: {
    description: "CaptureCat documentation",
    url: "https://capturecat.so/docs",
  },
  servers: [{ url: "https://api.capturecat.so", description: "CaptureCat API (Cloudflare Worker)" }],
  tags: [
    {
      name: "Screenshots",
      description:
        "Render a public web page to PNG, JPEG or WebP. Gated by plan, metered by a monthly quota, rate limited per IP.",
    },
    {
      name: "Screenshot keys",
      description:
        "Mint, list and revoke Screenshot API access keys. Session authentication only — an access key cannot manage keys.",
    },
    {
      name: "Stored screenshots",
      description: "Screenshots saved with `store=true`, which count against the user's storage. Session authentication only.",
    },
    { name: "Releases", description: "CaptureCat for Mac release metadata and DMG downloads. Public." },
    { name: "Health", description: "Liveness check. Public." },
    {
      name: "oEmbed",
      description: "oEmbed provider for CaptureCat share links, served by the website (https://capturecat.so). Public.",
    },
  ],
  paths: {
    "/api/screenshot/take": {
      get: {
        operationId: "takeScreenshot",
        summary: "Render a web page screenshot (query parameters)",
        description:
          "Use this when you need an image of a public web page: pass the options as query parameters and authenticate with an access key — prefer the `X-Access-Key` header, since an `access_key` query parameter can end up in logs. Returns the image bytes, or JSON with a presigned download URL when `store=true`. Session (bearer or cookie) callers are always refused here with 403 `forbidden`. " +
          TAKE_COMMON_DESCRIPTION,
        tags: ["Screenshots"],
        security: [{ accessKeyHeader: [] }, { accessKeyQuery: [] }],
        parameters: takeQueryParameters,
        responses: takeResponses("get"),
      },
      post: {
        operationId: "takeScreenshotFromJson",
        summary: "Render a web page screenshot (JSON body)",
        description:
          "Same as `takeScreenshot`, with the options as a JSON object body — use it when the options are long (many `hide_selectors`) or your client prefers JSON. Authenticate with the `X-Access-Key` header (or `access_key` in the query string or body). A Better Auth session is accepted only from the CaptureCat web app: the request must carry an `Origin` of https://capturecat.so, https://www.capturecat.so, https://app.capturecat.so or https://admin.capturecat.so, and session callers are gated on the plan's web-capture feature instead of the screenshot-API feature; any other session request gets 403 `forbidden`. " +
          TAKE_COMMON_DESCRIPTION,
        tags: ["Screenshots"],
        security: [{ accessKeyHeader: [] }, { accessKeyQuery: [] }, { sessionBearer: [] }],
        requestBody: {
          required: true,
          description: "The render options as one JSON object (same names and rules as the GET query parameters).",
          content: json("TakeScreenshotOptions"),
        },
        responses: takeResponses("post"),
      },
    },
    "/api/screenshot/keys": {
      post: {
        operationId: "createScreenshotKey",
        summary: "Mint a Screenshot API access key",
        description:
          "Use this once, as the signed-in user, to obtain the access key an API client or agent will send as `X-Access-Key`. The plaintext key is in this response ONLY — just its SHA-256 hash is stored, so it cannot be shown again. Requires a plan that includes the screenshot API (403 `upgrade_required`) and fewer than 5 active (unrevoked) keys (400 `too_many_keys`). Session only: an access key cannot mint keys. Per-IP rate limit: 30 requests per 60-second window for /api/screenshot/keys*.",
        tags: ["Screenshot keys"],
        security: [{ sessionBearer: [] }],
        requestBody: {
          required: false,
          description: "Optional. An empty or non-JSON body is accepted and means no label.",
          content: json("CreateScreenshotKeyRequest"),
        },
        responses: {
          "200": {
            description: "The new key. Store `key` now; it is never returned again.",
            headers: rateLimitHeaders,
            content: json("CreatedScreenshotKey"),
          },
          "400": {
            description: "`too_many_keys`: the user already has 5 active keys. Revoke one first.",
            content: json("ScreenshotError"),
          },
          "401": { description: "`unauthorized`: no valid session.", content: json("ScreenshotError") },
          "403": {
            description: "`account_blocked`, or `upgrade_required` (the plan does not include the screenshot API).",
            content: json("ScreenshotError"),
          },
          "429": { $ref: "#/components/responses/RateLimited" },
        },
      },
      get: {
        operationId: "listScreenshotKeys",
        summary: "List Screenshot API access keys",
        description:
          "Use this to see which access keys the signed-in user has — for example to find the id of a key to revoke. Newest first, revoked keys included (`revokedAt` set). Secrets are never returned. Session only. Per-IP rate limit: 30 requests per 60-second window for /api/screenshot/keys*.",
        tags: ["Screenshot keys"],
        security: [{ sessionBearer: [] }],
        responses: {
          "200": {
            description: "All of the user's keys, newest first.",
            headers: rateLimitHeaders,
            content: json("ScreenshotKeyList"),
          },
          "401": { description: "`unauthorized`: no valid session.", content: json("ScreenshotError") },
          "429": { $ref: "#/components/responses/RateLimited" },
        },
      },
    },
    "/api/screenshot/keys/{id}": {
      delete: {
        operationId: "revokeScreenshotKey",
        summary: "Revoke a Screenshot API access key",
        description:
          "Use this to revoke a leaked or unused access key; it stops working on the next request. Revoked keys stay in the list with `revokedAt` set and stop counting toward the 5-active-key limit. Session only. Per-IP rate limit: 30 requests per 60-second window for /api/screenshot/keys*.",
        tags: ["Screenshot keys"],
        security: [{ sessionBearer: [] }],
        parameters: [
          {
            name: "id",
            in: "path",
            required: true,
            description:
              "The key's `id` from `createScreenshotKey` or `listScreenshotKeys` (16 lowercase letters and digits — the part after `cc_live_` and before the next `_`).",
            schema: { type: "string" },
          },
        ],
        responses: {
          "200": {
            description: "The key is revoked.",
            headers: rateLimitHeaders,
            content: json("RevokedScreenshotKey"),
          },
          "401": { description: "`unauthorized`: no valid session.", content: json("ScreenshotError") },
          "404": {
            description: "`not_found`: the caller has no ACTIVE key with that id (unknown, someone else's, or already revoked).",
            content: json("ScreenshotError"),
          },
          "429": { $ref: "#/components/responses/RateLimited" },
        },
      },
    },
    "/api/screenshot/stored": {
      get: {
        operationId: "listStoredScreenshots",
        summary: "List stored screenshots",
        description:
          "Use this to see which screenshots saved with `store=true` count against the user's storage, e.g. before freeing space with `deleteStoredScreenshot`. Newest first. No download URLs are returned; repeating the original `takeScreenshot` call with `store=true` returns a fresh one (it overwrites the same object but consumes a render). Session only. Shares the 10-requests-per-60-seconds per-IP limit with /api/screenshot/take.",
        tags: ["Stored screenshots"],
        security: [{ sessionBearer: [] }],
        responses: {
          "200": {
            description: "The user's stored screenshots, newest first.",
            headers: rateLimitHeaders,
            content: json("StoredScreenshotList"),
          },
          "401": { description: "`unauthorized`: no valid session.", content: json("ScreenshotError") },
          "429": { $ref: "#/components/responses/RateLimited" },
        },
      },
    },
    "/api/screenshot/stored/{hash}": {
      delete: {
        operationId: "deleteStoredScreenshot",
        summary: "Delete a stored screenshot",
        description:
          "Use this to delete a screenshot saved with `store=true` and free its storage. Pass the last path segment of its `key` (`{cache_key}.{format}`). A user can only ever address their own objects. Session only. Shares the 10-requests-per-60-seconds per-IP limit with /api/screenshot/take.",
        tags: ["Stored screenshots"],
        security: [{ sessionBearer: [] }],
        parameters: [
          {
            name: "hash",
            in: "path",
            required: true,
            description:
              "The stored object's file name INCLUDING its extension: `{cache_key}.{format}`, e.g. `0123456789abcdef0123456789abcdef.png` — the `key` from `listStoredScreenshots` without its `screenshots/{userId}/` prefix, or `cache_key` + `.` + `format` from a `store=true` response.",
            schema: { type: "string", pattern: "^[A-Za-z0-9._-]{1,120}$", maxLength: 120 },
          },
        ],
        responses: {
          "200": {
            description: "The stored screenshot is deleted.",
            headers: rateLimitHeaders,
            content: json("DeletedStoredScreenshot"),
          },
          "400": {
            description: "`bad_request`: the path segment does not match `^[A-Za-z0-9._-]{1,120}$`.",
            content: json("ScreenshotError"),
          },
          "401": { description: "`unauthorized`: no valid session.", content: json("ScreenshotError") },
          "404": {
            description: "`not_found`: the caller has no stored screenshot with that name.",
            content: json("ScreenshotError"),
          },
          "429": { $ref: "#/components/responses/RateLimited" },
        },
      },
    },
    "/api/releases/latest": {
      get: {
        operationId: "getLatestRelease",
        summary: "Get the latest stable Mac release",
        description:
          "Use this to find the current stable version of CaptureCat for Mac, its release notes, minimum macOS version and DMG download URLs. Returns the published release record as stored (cached for 5 minutes).",
        tags: ["Releases"],
        security: [],
        responses: {
          "200": {
            description: "The latest stable release.",
            headers: { "Cache-Control": { $ref: "#/components/headers/CacheControlFiveMinutes" } },
            content: json("Release"),
          },
          "404": { description: "`{\"error\":\"No release found\"}`: nothing has been published.", content: json("SimpleError") },
        },
      },
    },
    "/api/releases/latest-beta": {
      get: {
        operationId: "getLatestBetaRelease",
        summary: "Get the latest beta Mac release",
        description:
          "Use this to find the newest BETA build of CaptureCat for Mac (for testers). Same record shape as `getLatestRelease`, with `channel` = `beta`. Cached for 5 minutes.",
        tags: ["Releases"],
        security: [],
        responses: {
          "200": {
            description: "The latest beta release.",
            headers: { "Cache-Control": { $ref: "#/components/headers/CacheControlFiveMinutes" } },
            content: json("Release"),
          },
          "404": { description: "`{\"error\":\"No beta release found\"}`: no beta has been published.", content: json("SimpleError") },
        },
      },
    },
    "/api/releases/versions": {
      get: {
        operationId: "listReleases",
        summary: "List every published Mac release",
        description:
          "Use this for the full public release history (stable and beta, newest build first) — for example to find an older version's DMG. Sparkle signatures are stripped from these records. Returns an empty list (never 404) when there is no history. Cached for 5 minutes.",
        tags: ["Releases"],
        security: [],
        responses: {
          "200": {
            description: "The release history, newest build first.",
            headers: { "Cache-Control": { $ref: "#/components/headers/CacheControlFiveMinutes" } },
            content: json("ReleaseList"),
          },
        },
      },
    },
    "/api/releases/download/{arch}": {
      get: {
        operationId: "downloadLatestRelease",
        summary: "Download the latest stable Mac DMG",
        description:
          "Use this to download the installer for the latest STABLE release: `arm64` for Apple silicon, `x86_64` for Intel Macs. Streams the DMG as an attachment named `CaptureCat.dmg`. The whole file is always returned with status 200; a `Range` header only decides whether the request is counted as a new download (a range starting at byte 0, or none, counts). The optional `ref` / `utm_*` / `lp` query parameters are analytics-only.",
        tags: ["Releases"],
        security: [],
        parameters: [
          {
            name: "arch",
            in: "path",
            required: true,
            description: "CPU architecture: `arm64` (Apple silicon) or `x86_64` (Intel).",
            schema: { type: "string", enum: ["arm64", "x86_64"] },
          },
          {
            name: "ref",
            in: "query",
            required: false,
            description:
              "Analytics only — the referring page's URL for download attribution (falls back to the `Referer` header). Does not change the response.",
            schema: { type: "string" },
          },
          {
            name: "utm_source",
            in: "query",
            required: false,
            description: "Analytics only — UTM source for download attribution. Does not change the response.",
            schema: { type: "string" },
          },
          {
            name: "utm_medium",
            in: "query",
            required: false,
            description: "Analytics only — UTM medium for download attribution. Does not change the response.",
            schema: { type: "string" },
          },
          {
            name: "utm_campaign",
            in: "query",
            required: false,
            description: "Analytics only — UTM campaign for download attribution. Does not change the response.",
            schema: { type: "string" },
          },
          {
            name: "lp",
            in: "query",
            required: false,
            description:
              "Analytics only — the site landing path of the visit that led to the download. Does not change the response.",
            schema: { type: "string" },
          },
        ],
        responses: {
          "200": {
            description: "The DMG file.",
            headers: {
              "Content-Disposition": {
                description: "`attachment; filename=\"CaptureCat.dmg\"`.",
                schema: { type: "string" },
              },
              "Content-Length": { description: "Size of the DMG in bytes.", schema: { type: "integer" } },
              "Cache-Control": { $ref: "#/components/headers/CacheControlFiveMinutes" },
            },
            content: {
              "application/octet-stream": {
                schema: { type: "string", format: "binary", description: "macOS disk image (DMG)." },
              },
            },
          },
          "400": {
            description: "`{\"error\":\"Invalid architecture. Use arm64 or x86_64\"}`.",
            content: json("SimpleError"),
          },
          "404": {
            description:
              "`{\"error\":\"No release found\"}` (nothing published) or `{\"error\":\"File not found\"}` (no DMG for that architecture).",
            content: json("SimpleError"),
          },
        },
      },
    },
    "/api/releases/{version}/{file}": {
      get: {
        operationId: "downloadReleaseFile",
        summary: "Download a specific Mac release DMG",
        description:
          "Use this to download the DMG of a specific (possibly older) release. The `downloads` URLs in release records point here. Streams the file as an attachment under its own name; cached for a day. (`/api/releases/download/{arch}` takes precedence when `version` is `download`.)",
        tags: ["Releases"],
        security: [],
        parameters: [
          {
            name: "version",
            in: "path",
            required: true,
            description: "Release version as listed by `listReleases`, e.g. `1.2.0`.",
            schema: { type: "string" },
          },
          {
            name: "file",
            in: "path",
            required: true,
            description:
              "DMG file name, e.g. `CaptureCat-arm64.dmg` or `CaptureCat-x86_64.dmg` — take it from the release's `downloads`. Names not ending in `.dmg` return 404.",
            schema: { type: "string", pattern: "\\.dmg$" },
          },
        ],
        responses: {
          "200": {
            description: "The DMG file.",
            headers: {
              "Content-Disposition": {
                description: "`attachment; filename=\"{file}\"`.",
                schema: { type: "string" },
              },
              "Content-Length": { description: "Size of the DMG in bytes.", schema: { type: "integer" } },
              "Cache-Control": {
                description: "`public, max-age=86400`.",
                schema: { type: "string" },
              },
            },
            content: {
              "application/octet-stream": {
                schema: { type: "string", format: "binary", description: "macOS disk image (DMG)." },
              },
            },
          },
          "404": {
            description:
              "`{\"error\":\"Not found\"}` (the file name does not end in `.dmg`) or `{\"error\":\"File not found\"}` (no such version/file).",
            content: json("SimpleError"),
          },
        },
      },
    },
    "/api/health": {
      get: {
        operationId: "getHealth",
        summary: "Check API health",
        description:
          "Use this to check that the CaptureCat API is up before making other calls, or for uptime monitoring. Always `{ \"status\": \"ok\" }` when the Worker is serving. No authentication, no rate limit.",
        tags: ["Health"],
        security: [],
        responses: {
          "200": { description: "The API is serving requests.", content: json("HealthStatus") },
        },
      },
    },
    "/api/oembed": {
      servers: [{ url: "https://capturecat.so", description: "CaptureCat website (web Worker)" }],
      get: {
        operationId: "getShareOembed",
        summary: "Get oEmbed data for a CaptureCat share link",
        description:
          "Use this to turn a CaptureCat share link (`https://capturecat.so/share/{videoId}`) into embeddable player HTML and a title, per the oEmbed spec (https://oembed.com). Served by the WEBSITE at https://capturecat.so/api/oembed, not by api.capturecat.so. Only `format=json` is supported, and `maxwidth` / `maxheight` are not supported (always 800×450). Public.",
        tags: ["oEmbed"],
        security: [],
        parameters: [
          {
            name: "url",
            in: "query",
            required: true,
            description:
              "The share link: `http(s)://capturecat.so/share/{videoId}` or the same on `www.capturecat.so`, where `videoId` is 4–64 characters of `A–Z a–z 0–9 _ -`. Anything after the id is ignored. A missing or unrecognised URL returns 404.",
            schema: { type: "string", format: "uri" },
          },
          {
            name: "format",
            in: "query",
            required: false,
            description: "Response format. Only `json`; any other value returns 501.",
            schema: { type: "string", enum: ["json"], default: "json" },
          },
        ],
        responses: {
          "200": { description: "oEmbed `video` response.", content: json("OEmbedVideo") },
          "404": {
            description:
              "`{\"error\":\"Unrecognized url\"}` (missing or not a share link) or `{\"error\":\"Not found\"}` (the video does not exist or its metadata could not be loaded).",
            content: json("SimpleError"),
          },
          "501": { description: "`{\"error\":\"Only json is supported\"}`: `format` was not `json`.", content: json("SimpleError") },
        },
      },
    },
  },
  components: {
    securitySchemes: {
      accessKeyHeader: {
        type: "apiKey",
        in: "header",
        name: "X-Access-Key",
        description:
          "Screenshot API access key, `cc_live_<16 chars>_<48 chars>` (lowercase letters and digits), minted with `createScreenshotKey`. Preferred way to send a key; checked before the query parameter, the body field and any session. Accepted ONLY by /api/screenshot/take — a key cannot manage keys or stored screenshots.",
      },
      accessKeyQuery: {
        type: "apiKey",
        in: "query",
        name: "access_key",
        description:
          "The same access key as a query parameter (the `access_key` convention common to screenshot APIs). Used when no `X-Access-Key` header is sent. Accepted ONLY by /api/screenshot/take. POST /api/screenshot/take also reads an `access_key` field in the JSON body as a last resort.",
      },
      sessionBearer: {
        type: "http",
        scheme: "bearer",
        bearerFormat: "Better Auth session token",
        description:
          "A signed-in CaptureCat session (Better Auth bearer plugin): `Authorization: Bearer <session token>`, as the CaptureCat Mac app sends it. In a browser on capturecat.so the Better Auth session cookie is accepted the same way. Required for key management and stored screenshots; an access key is never accepted there. On /api/screenshot/take a session is honoured only for POSTs from the CaptureCat web app.",
      },
    },
    headers: {
      XRateLimitLimit: {
        description: "Requests allowed per 60-second window for this route family and client IP.",
        schema: { type: "integer" },
      },
      XRateLimitRemaining: {
        description: "Requests left in the current 60-second window for this client IP.",
        schema: { type: "integer" },
      },
      RetryAfter: {
        description: "On a rate-limit 429: the window length in seconds (always `60`), not the time left in the window.",
        schema: { type: "integer" },
      },
      XScreenshotQuotaLimit: {
        description: "The plan's monthly render quota (0 when the plan includes none). Set once the quota check has run.",
        schema: { type: "integer", minimum: 0 },
      },
      XScreenshotQuotaRemaining: {
        description: "Renders left this UTC calendar month, after this request. Set once the quota check has run.",
        schema: { type: "integer", minimum: 0 },
      },
      CacheControlFiveMinutes: {
        description: "`public, max-age=300`.",
        schema: { type: "string" },
      },
    },
    responses: {
      RateLimited: {
        description:
          "Per-IP rate limit exceeded: `{\"error\":\"Too many requests\"}`. Wait `Retry-After` seconds.",
        headers: { "Retry-After": { $ref: "#/components/headers/RetryAfter" } },
        content: json("RateLimitError"),
      },
    },
    schemas: {
      TakeScreenshotOptions: {
        type: "object",
        description:
          "Render options for POST /api/screenshot/take — the same names and rules as the GET query parameters, plus an optional `access_key`. Unknown keys are ignored.",
        required: ["url"],
        properties: takeBodyProperties,
      },
      TakeScreenshotStoredResult: {
        type: "object",
        description: "Response of /api/screenshot/take when `store=true`.",
        required: ["cache_key", "key", "url", "expires_in", "format"],
        properties: {
          cache_key: {
            type: "string",
            pattern: "^[0-9a-f]{32}$",
            description:
              "Deterministic hash of the url + options (32 hex characters). The same request always maps to the same stored object.",
          },
          key: {
            type: "string",
            description:
              "Storage key `screenshots/{userId}/{cache_key}.{format}`. Its last segment is what `deleteStoredScreenshot` takes.",
          },
          url: { type: "string", format: "uri", description: "Presigned download URL for the image, valid for `expires_in` seconds." },
          expires_in: { type: "integer", const: 3600, description: "Lifetime of `url` in seconds." },
          format: { type: "string", enum: ["png", "jpeg", "webp"], description: "Image format of the stored object." },
        },
      },
      CreateScreenshotKeyRequest: {
        type: "object",
        properties: {
          label: {
            type: "string",
            description:
              "Optional name for the key. Trimmed and cut to 60 characters (longer labels are truncated, not refused); blank or non-string means no label.",
          },
        },
      },
      CreatedScreenshotKey: {
        type: "object",
        required: ["id", "key", "label"],
        properties: {
          id: { type: "string", description: "Key id (16 lowercase letters and digits). Use it to revoke the key." },
          key: {
            type: "string",
            pattern: "^cc_live_[a-z0-9]{16}_[a-z0-9]{48}$",
            description: "The full access key. Shown ONLY in this response; send it as `X-Access-Key`.",
          },
          label: { type: ["string", "null"], description: "The stored label, or null." },
        },
      },
      ScreenshotKey: {
        type: "object",
        required: ["id", "label", "createdAt", "revokedAt"],
        properties: {
          id: { type: "string", description: "Key id (16 lowercase letters and digits)." },
          label: { type: ["string", "null"], description: "Label given at creation, or null." },
          createdAt: { type: "string", format: "date-time", description: "When the key was minted (ISO 8601, UTC)." },
          revokedAt: {
            type: ["string", "null"],
            format: "date-time",
            description: "When the key was revoked (ISO 8601, UTC), or null while it is active.",
          },
        },
      },
      ScreenshotKeyList: {
        type: "object",
        required: ["keys"],
        properties: {
          keys: { type: "array", items: ref("ScreenshotKey"), description: "Newest first, revoked keys included." },
        },
      },
      RevokedScreenshotKey: {
        type: "object",
        required: ["id", "revoked"],
        properties: {
          id: { type: "string", description: "The revoked key's id." },
          revoked: { type: "boolean", const: true },
        },
      },
      StoredScreenshot: {
        type: "object",
        required: ["key", "bytes", "createdAt"],
        properties: {
          key: {
            type: "string",
            description:
              "Storage key `screenshots/{userId}/{cache_key}.{format}`. Pass its last segment to `deleteStoredScreenshot`.",
          },
          bytes: { type: "integer", minimum: 0, description: "Size in bytes, counted against the storage cap." },
          createdAt: {
            type: "string",
            format: "date-time",
            description: "When it was (last) stored, ISO 8601 UTC. Re-storing the same request updates it.",
          },
        },
      },
      StoredScreenshotList: {
        type: "object",
        required: ["objects"],
        properties: {
          objects: { type: "array", items: ref("StoredScreenshot"), description: "Newest first." },
        },
      },
      DeletedStoredScreenshot: {
        type: "object",
        required: ["ok", "key"],
        properties: {
          ok: { type: "boolean", const: true },
          key: { type: "string", description: "The deleted storage key, `screenshots/{userId}/{cache_key}.{format}`." },
        },
      },
      ScreenshotErrorCode: {
        type: "string",
        description:
          "Machine-readable error code of the /api/screenshot/* endpoints, with its HTTP status: " +
          "`invalid_request` 400 (POST body is not a JSON object), " +
          "`missing_parameter` 400 (no `url`), " +
          "`invalid_url` 400, " +
          "`host_not_allowed` 400 (private, internal or blocklisted host), " +
          "`invalid_parameter` 400 (an option is out of range or malformed), " +
          "`engine_unavailable` 400, " +
          "`too_many_keys` 400 (5 active keys already), " +
          "`bad_request` 400 (invalid stored-screenshot name), " +
          "`unauthorized` 401, " +
          "`cloud_share_required` 402 and `no_storage_allowance` 402 (store=true without storage on the plan), " +
          "`forbidden` 403 (session caller outside the CaptureCat web app), " +
          "`account_blocked` 403, " +
          "`upgrade_required` 403 (plan does not include the feature), " +
          "`not_found` 404, " +
          "`file_too_large` 413 and `storage_limit_reached` 413 (store=true over the plan's storage limits), " +
          "`quota_exceeded` 429 (monthly render quota used up), " +
          "`render_failed` 502, " +
          "`not_configured` 503, " +
          "`timeout` 504.",
        enum: [
          "invalid_request",
          "missing_parameter",
          "invalid_url",
          "host_not_allowed",
          "invalid_parameter",
          "engine_unavailable",
          "too_many_keys",
          "bad_request",
          "unauthorized",
          "cloud_share_required",
          "no_storage_allowance",
          "forbidden",
          "account_blocked",
          "upgrade_required",
          "not_found",
          "file_too_large",
          "storage_limit_reached",
          "quota_exceeded",
          "render_failed",
          "not_configured",
          "timeout",
        ],
      },
      ScreenshotError: {
        type: "object",
        description: "Error body of the /api/screenshot/* endpoints: { error: { code, message } }.",
        required: ["error"],
        properties: {
          error: {
            type: "object",
            required: ["code", "message"],
            properties: {
              code: ref("ScreenshotErrorCode"),
              message: { type: "string", description: "Human-readable explanation. Branch on `code`, not on this text." },
            },
          },
        },
      },
      RateLimitError: {
        type: "object",
        description: "Body of a per-IP rate-limit 429 (any rate-limited route).",
        required: ["error"],
        properties: {
          error: { type: "string", const: "Too many requests" },
        },
      },
      SimpleError: {
        type: "object",
        description: "Error body of the release and oEmbed endpoints.",
        required: ["error"],
        properties: {
          error: { type: "string", description: "Human-readable error message." },
        },
      },
      ReleaseDownloads: {
        type: "object",
        description: "Direct DMG URLs per architecture (served by `downloadReleaseFile`).",
        properties: {
          arm64: { type: "string", format: "uri", description: "Apple silicon DMG." },
          x86_64: { type: "string", format: "uri", description: "Intel DMG." },
        },
      },
      ReleaseSignature: {
        type: "object",
        description: "Sparkle auto-update signature of one DMG.",
        properties: {
          edSignature: { type: "string", description: "Base64 EdDSA signature." },
          length: { type: "integer", minimum: 0, description: "DMG size in bytes." },
        },
      },
      ReleaseSummary: {
        type: "object",
        description:
          "A published Mac release, passed through as stored by the release script (unknown extra fields are passed through too, so only `version` is guaranteed).",
        required: ["version"],
        properties: {
          version: { type: "string", description: "Marketing version, e.g. `1.2.0`." },
          build: { type: "integer", description: "Build number; history is ordered by it, newest first." },
          channel: { type: "string", enum: ["stable", "beta"], description: "Release channel." },
          date: { type: "string", format: "date", description: "Publish date, `YYYY-MM-DD`." },
          pubDate: { type: "string", description: "Publish timestamp in RFC 2822 form, e.g. `Wed, 07 Oct 2026 11:02:36 +0100`." },
          minOS: { type: "string", description: "Minimum macOS version, e.g. `14.0`." },
          notes: { type: "string", description: "Release notes (plain text, one `- ` line per change)." },
          downloads: ref("ReleaseDownloads"),
        },
      },
      Release: {
        description: "A release record as returned by the latest / latest-beta endpoints, including Sparkle signatures.",
        allOf: [
          ref("ReleaseSummary"),
          {
            type: "object",
            properties: {
              signatures: {
                type: "object",
                description: "Sparkle signatures per architecture.",
                properties: {
                  arm64: ref("ReleaseSignature"),
                  x86_64: ref("ReleaseSignature"),
                },
              },
            },
          },
        ],
      },
      ReleaseList: {
        type: "object",
        required: ["releases"],
        properties: {
          releases: {
            type: "array",
            items: ref("ReleaseSummary"),
            description: "Every published release, both channels, newest build first. Empty when there is no history.",
          },
        },
      },
      HealthStatus: {
        type: "object",
        required: ["status"],
        properties: {
          status: { type: "string", const: "ok" },
        },
      },
      OEmbedVideo: {
        type: "object",
        description: "oEmbed 1.0 `video` response for a CaptureCat share link.",
        required: ["version", "type", "provider_name", "provider_url", "title", "html", "width", "height"],
        properties: {
          version: { type: "string", const: "1.0" },
          type: { type: "string", const: "video" },
          provider_name: { type: "string", const: "CaptureCat" },
          provider_url: { type: "string", const: "https://capturecat.so" },
          title: {
            type: "string",
            description: "The recording's file name, or `CaptureCat recording` when it has none.",
          },
          html: {
            type: "string",
            description:
              "An `<iframe>` of `https://capturecat.so/embed/{videoId}`, 800×450, fullscreen allowed, styled to fill its container's width at 16:9.",
          },
          width: { type: "integer", const: 800 },
          height: { type: "integer", const: 450 },
        },
      },
    },
  },
} as const;
