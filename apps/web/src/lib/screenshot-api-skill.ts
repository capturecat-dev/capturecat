/**
 * SKILL.md for the Screenshot API (served under /.well-known/agent-skills/).
 * Facts come from the OpenAPI description (lib/openapi.ts) — change together.
 */
import type { AgentSkill } from "./agent-skills";
import { SITE_URL } from "./site-url";

export const SCREENSHOT_API_SKILL: AgentSkill = {
  name: "capturecat-screenshot-api",
  description:
    "Render any http(s) URL to a PNG, JPEG or WebP image (viewport or full page) with the CaptureCat Screenshot API.",
  markdown: `---
name: capturecat-screenshot-api
description: Render any http(s) URL to a PNG, JPEG or WebP image (viewport or full page) with the CaptureCat Screenshot API.
---

# CaptureCat Screenshot API

## When to use this

Use it when code or an agent needs an image of a web page: a full-page
capture for docs or QA, a social preview, a dark-mode or mobile view, or a
clean shot with cookie banners and chat widgets hidden. It needs a CaptureCat
access key on a plan that includes the Screenshot API (Pro: 1,000 a month).

Do not use it to record video (use the CaptureCat app or its MCP server), or
for pages behind a login: there are no cookie or header options.

## Call it

\`\`\`sh
curl -o page.png \\
  -H "X-Access-Key: $CAPTURECAT_KEY" \\
  "https://api.capturecat.so/api/screenshot/take?url=https://example.com&full_page=true"
\`\`\`

- \`GET /api/screenshot/take\` with query parameters, or \`POST\` the same fields
  as JSON. The key goes in \`X-Access-Key\` (or the \`access_key\` parameter).
- The body is the image; \`Content-Type\` follows \`format\`.
- Useful fields: \`url\` (required), \`device\` (\`desktop\` | \`tablet\` | \`mobile\`),
  \`viewport_width\`/\`viewport_height\` (100–3840), \`device_scale_factor\` (1–3),
  \`full_page\` + \`max_height_multiple\` (1–10), \`format\` (\`png\` | \`jpeg\` | \`webp\`),
  \`quality\` (1–100), \`delay\` (0–10 s), \`timeout\` (1–30 s), \`dark_mode\`,
  \`reduced_motion\`, \`block_cookie_banners\`, \`block_chats\`, \`hide_selectors\`
  (≤ 20), \`click_selector\`, \`store\` (keep it and get JSON with a download URL).

## Errors

JSON \`{ "error": { "code", "message" } }\`. Fix the input and retry on 400
(\`invalid_url\`, \`invalid_parameter\`, \`missing_parameter\`, \`host_not_allowed\`).
401 \`unauthorized\`: wrong or revoked key. 403 \`upgrade_required\`: the account's
plan lacks the API. 429: \`quota_exceeded\` (monthly, resets on the 1st UTC) or
the per-IP rate limit (10 a minute) — back off. 502 \`render_failed\` / 504
\`timeout\`: the page itself failed; try a longer \`timeout\` once, then report.

## Keys

Keys are created with \`POST /api/screenshot/keys\` from a signed-in CaptureCat
session; a key cannot create, list or revoke keys. Never put a key in a URL you
share or log. See ${SITE_URL}/auth.md.

Full reference: ${SITE_URL}/docs/api · OpenAPI: ${SITE_URL}/openapi.json
`,
};
