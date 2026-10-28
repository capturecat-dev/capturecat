import type { DocSection } from "../types";

/**
 * The developer API (api.capturecat.so). Every claim here is in the OpenAPI
 * description (lib/openapi.ts), which was written from apps/api
 * routes/screenshot.ts, lib/screenshot/params.ts and routes/releases.ts —
 * change them together.
 */
export const API: DocSection = {
  id: "api",
  title: "API",
  description: "Screenshots of any URL, the release feed and oEmbed, over HTTPS.",
  pages: [
    {
      slug: "api",
      title: "CaptureCat API: screenshots, releases and oEmbed",
      navTitle: "Overview",
      seoTitle: "CaptureCat API reference | CaptureCat Docs",
      description:
        "The CaptureCat API: render any URL to PNG, JPEG or WebP with the Screenshot API, read the Mac release feed, and embed share links with oEmbed.",
      summary:
        "The CaptureCat API at `https://api.capturecat.so` renders any web page to an image (the Screenshot API, on Pro), publishes the Mac app's release feed, and serves oEmbed for share links. The full machine-readable description is [openapi.json](https://capturecat.so/openapi.json).",
      plan: "pro",
      blocks: [
        { type: "h2", text: "What is in the API" },
        {
          type: "table",
          head: ["Operation", "Endpoint", "Auth"],
          rows: [
            ["Take a screenshot", "`GET` or `POST /api/screenshot/take`", "Access key"],
            ["Manage access keys", "`POST`, `GET /api/screenshot/keys`, `DELETE /api/screenshot/keys/{id}`", "Signed-in session only"],
            ["List or delete stored screenshots", "`GET /api/screenshot/stored`, `DELETE /api/screenshot/stored/{hash}`", "Signed-in session only"],
            ["Manage agent tokens for the remote MCP server", "`GET`, `POST /api/agent-tokens`, `DELETE /api/agent-tokens/{id}`, `GET /api/agent-tokens/audit`", "Signed-in session only"],
            ["Latest Mac release", "`GET /api/releases/latest`", "None"],
            ["Download the Mac app", "`GET /api/releases/download/{arch}` (`arm64` or `x86_64`)", "None"],
            ["Embed a share link", "`GET https://capturecat.so/api/oembed?url=…`", "None"],
            ["Health", "`GET /api/health`", "None"],
          ],
        },
        { type: "h2", text: "Authentication" },
        {
          type: "p",
          text: "The Screenshot API takes an **access key**, either in the `X-Access-Key` header or as the `access_key` query parameter. Keys are created with `POST /api/screenshot/keys`, which only accepts a signed-in CaptureCat session: a key can take screenshots but can never create, list or revoke keys. Revoke a key with `DELETE /api/screenshot/keys/{id}`.",
        },
        {
          type: "callout",
          tone: "pro",
          text: "The Screenshot API needs a plan that includes it: Pro does, with 1,000 screenshots a month. On a plan without it, `take` answers 403 `upgrade_required`; past the monthly allowance it answers 429 `quota_exceeded`.",
        },
        { type: "h2", text: "Take a screenshot" },
        {
          type: "code",
          lang: "bash",
          code: 'curl -o page.png \\\n  -H "X-Access-Key: $CAPTURECAT_KEY" \\\n  "https://api.capturecat.so/api/screenshot/take?url=https://example.com&full_page=true&format=png"',
          caption: "The response body is the image. POST takes the same fields as a JSON body.",
        },
        {
          type: "table",
          head: ["Parameter", "What it does"],
          rows: [
            ["`url`", "Required. The http(s) page to render."],
            ["`device`", "`desktop` (1440×900 at 2x), `tablet` or `mobile`: seeds the viewport and user agent."],
            ["`viewport_width`, `viewport_height`", "100–3840 CSS pixels each."],
            ["`device_scale_factor`", "1–3."],
            ["`full_page`", "Capture the whole scrollable page; `max_height_multiple` (1–10) caps its height."],
            ["`format`", "`png` (default), `jpeg` or `webp`; `quality` 1–100 for jpeg and webp."],
            ["`delay`", "0–10 extra seconds after load (default 0)."],
            ["`timeout`", "1–30 seconds to load (default 30)."],
            ["`dark_mode`, `reduced_motion`", "Best-effort media-query emulation."],
            ["`block_cookie_banners`, `block_chats`", "Hide consent banners and live-chat widgets."],
            ["`hide_selectors`", "Up to 20 comma-separated CSS selectors to hide."],
            ["`click_selector`", "One element to click before capturing."],
            ["`store`", "Also save the image to your CaptureCat storage and answer JSON with a download link."],
          ],
        },
        { type: "h2", text: "Errors and limits" },
        {
          type: "p",
          text: "Errors are JSON shaped `{ \"error\": { \"code\": \"…\", \"message\": \"…\" } }`: 400 for invalid parameters (for example `invalid_url`), 401 `unauthorized` for a missing, unknown or revoked key, 403 `upgrade_required`, 429 `quota_exceeded` or the rate limit, 502 `render_failed` and 504 `timeout` when the page cannot be rendered, and, with `store=true` only, 402 or 413 when your plan or storage cannot keep the image. `/api/screenshot/*` is rate limited per IP (10 requests a minute for `take` and `stored`, 30 for `keys`). Every code and status is in the OpenAPI description.",
        },
        { type: "h2", text: "For agents and tools" },
        {
          type: "list",
          items: [
            "[OpenAPI 3.1 description](https://capturecat.so/openapi.json): every operation with an `operationId`, typed parameters and response schemas, ready for function calling.",
            "[API catalog](https://capturecat.so/.well-known/api-catalog) (RFC 9727) and [AI catalog](https://capturecat.so/.well-known/ai-catalog.json).",
            "Remote MCP server at `https://mcp.capturecat.so/mcp` for cloud agents, authenticated with a scoped agent token (`Authorization: Bearer cc_pat_…`) created in Settings → Agent access. Its [server card](https://capturecat.so/.well-known/mcp/server-card.json) lists the tools and the scope each needs.",
            "[auth.md](https://capturecat.so/auth.md): how agents authenticate.",
            "[Agent skills](https://capturecat.so/.well-known/agent-skills/index.json): SKILL.md files for this API and the local and remote MCP servers.",
          ],
        },
      ],
      related: ["ai-agents", "self-hosting/api"],
      lastModified: "2026-10-28",
    },
  ],
};
