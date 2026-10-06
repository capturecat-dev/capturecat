# Competitor fact research brief (today is 2026-10-06)

You are researching screen-recording products for comparison pages on capturecat.so.
These pages are read by people AND quoted by AI answer engines, so EVERY claim must be TRUE
and CURRENT. A wrong claim about a competitor is worse than no claim.

## Rules
- Use WebSearch and WebFetch. Prefer the product's OWN site (pricing page, features page, docs,
  changelog, help center) over third-party listicles. Fetch the pricing page directly.
- Every non-null fact needs at least one source URL you actually fetched or saw in search results.
- If you cannot verify a fact, use null. Never guess. Never carry over "common knowledge".
- Prices: give the current list price with currency and billing period, e.g. "$29/mo or $229/yr".
  If the product has several tiers, summarise the range (e.g. "Free · paid from $12/user/mo").
- Note if the product was discontinued, acquired, renamed, or Mac support dropped.
- Write in plain, neutral English. No marketing superlatives. No em-dash-heavy prose. Be fair:
  every competitor has real strengths; say them.

## The feature cells (must answer each, in this order)
Each cell is: true | false | short string (≤ 40 chars, for nuance) | null (unverified).
1. autoZoom: automatic zoom/pan that follows clicks or cursor without manual keyframes.
   true only if automatic. Manual-only zoom → "Manual zoom only". None → false.
2. cursorEffects: cursor smoothing and/or click highlights/ripples applied in post. Nuance OK
   (e.g. "Click highlights only").
3. captions: auto captions/transcription. If it exists, say WHERE it runs:
   on-device → true; cloud → "Cloud auto-captions"; paid tier only → add that, e.g. "Cloud, paid plans".
   None → false.
4. mcp: does the product offer an official MCP (Model Context Protocol) server or official
   AI-agent API for editing/recording? Search "<product> MCP server" specifically.
   true / false / short nuance (e.g. "Official MCP, read-only").
5. shareAnalytics: hosted share links with viewer analytics (views, watch time).
   true / "Share links, no analytics" / false.
6. freeVersion: short description of the free tier ("Free, 5-min limit, watermark", "Trial only",
   "Fully free", "No free tier").
7. openSource: true (name the licence in notes) / false.
8. platform: e.g. "macOS", "macOS & Windows", "Windows only", "Browser (Chrome extension)".
9. price: short current price summary.

## Also write (these are rendered on the page)
- summary: one neutral sentence on what the product is.
- strengths: 3 short bullets (true, specific).
- tradeoffs: 3 short bullets (true, specific, fair; no invented weaknesses).
- pickThemWhen: completes the sentence "Pick <Name> when ..." (lowercase start, ends with a period).
- differentiator: 1-2 sentences, how CaptureCat differs, using ONLY the CaptureCat facts below.
  Be honest: if the competitor matches CaptureCat on something, say so.
- switchTip: 1-2 sentences on switching from them to CaptureCat (practical, honest).
- faqExtra (optional): one {question, answer} specific to this competitor, if a genuinely common
  question exists (e.g. "Does X work on Mac?"). Answer must be factual and sourced.
- slug: lowercase-hyphenated product name (e.g. "screenflow").
- website: canonical product URL.
- notes: anything surprising (price change, acquisition, Mac version discontinued, etc.).
- sources: object mapping field name -> array of URLs.

## CaptureCat facts (the ONLY things you may claim about CaptureCat)
- Native macOS app (Swift/AppKit/Metal, not Electron), macOS 14+, Apple Silicon and Intel.
- Also a browser app (Chrome/Edge 113+, Safari 26+, Firefox 141+) on Windows, Linux, ChromeOS, Mac;
  browser projects live in cloud storage that comes with Pro.
- Free forever: unlimited recording, the full editor, automatic zoom from recorded clicks,
  cursor smoothing with click ripples, on-device captions (English, local Whisper model),
  export MP4/MOV up to 4K 60 fps, no watermark.
- Pro subscription: share links with timestamped comments and viewer analytics (views, watch time,
  retention), AI titles/chapters on share pages, web page capture by URL.
- Built-in MCP server (28 tools) so Claude Code, Codex, Cursor, Copilot, Windsurf can record,
  edit, render frames, and export.
- Open source under AGPL-3.0 (github.com/capturecat-dev/capturecat).
- Records displays, windows, areas, iPhone/iPad over USB, camera bubble on its own track,
  system audio + mic; blur/pixelate, spotlights, annotations, keystroke overlay, device bezels.
- Preview and export render identically.
- No team plan yet. No Windows-native app (Windows users use the browser app).

## Output
Write a JSON array (one object per product, fields exactly as named above) to the file path you
are given, using the Write tool. Then reply with a short summary: per product, any cell you set to
null and why, and anything surprising.

## Extra field (batches F–I)
- category: one of "demo" (auto-zoom demo recorders), "async" (async video / share links for teams),
  "editor" (recorder bundled with a full video editor), "capture" (screenshot + capture utilities,
  game/performance recorders), "free" (free, open source, or built into the OS),
  "interactive" (AI product-video and interactive click-through demo tools).
- If a product does not actually record screen video (e.g. screenshot-only), or is discontinued,
  LEAVE IT OUT and say so in your reply. Do not pad the list.
