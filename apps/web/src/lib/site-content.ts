/**
 * One source of truth for the public marketing pages.
 *
 * robots.txt, sitemap.xml, llms.txt, the per-page Markdown routes, and each
 * page's `<link rel="alternate" type="text/markdown">` all read from here, so a
 * new page is added in exactly one place and every discovery surface follows.
 *
 * Auth-gated routes (/login, /app/*) and the dynamic /share/[videoId] pages are
 * deliberately absent: they are not stable public content for crawlers or
 * agents to index.
 */

import { SITE_URL } from "./site-url";
import { PSEO_SITE_PAGES } from "./pseo-content";
import { FEATURE_INVENTORY_MARKDOWN } from "./feature-inventory";

export { SITE_URL };

export interface SitePage {
  /** Route path, e.g. "/" or "/pricing". */
  path: string;
  title: string;
  description: string;
  /** W3C date (YYYY-MM-DD) of the last meaningful content change. */
  lastModified: string;
  /** Full Markdown rendering of the page, served at /{path}.md. */
  markdown: string;
}

const STATIC_PAGES: SitePage[] = [
  {
    path: "/",
    title: "Screen Recorder for Mac — CaptureCat",
    description:
      "A native Mac screen recorder that edits itself: automatic cinematic zooms, cursor smoothing, on-device captions, device frames, and share links with viewer analytics.",
    lastModified: "2026-08-14",
    markdown: `# CaptureCat — Screen Recorder for Mac

Screen recordings that look purrfect. Capture your Mac, then let CaptureCat do
the part that usually needs an editor — cinematic zooms, a steadied cursor, real
captions, and an export that matches the preview exactly.

## The editing is already done by the time you stop recording

- **Record** — pick a window, a display, or an area. Camera and mic come along
  if you want them; every click and keystroke is captured as data, not just
  pixels.
- **It edits itself** — CaptureCat replays your session and adds the
  cinematography: it zooms into the field you typed in, smooths the cursor path,
  and ripples each click.
- **Make it yours** — drop it on a wallpaper, add padding and shadow, frame it
  in a photoreal device bezel, and place on-device captions wherever you drag
  them.
- **Share** — export a file that matches the preview frame-for-frame, or upload
  and send a link, then watch views, drop-off, and comments roll in.

## Features

- **Zooms that feel filmed** — CaptureCat watches where you click and pushes in
  on it, on a spring that settles the way a camera operator would.
- **A cursor with manners** — smoothed motion, click ripples, and custom
  pointers that never drift off the pixel they were recorded over.
- **Captions worth reading** — transcribed on device; no audio ever leaves your
  Mac.
- **Framing, handled** — wallpapers, padding, shadows, a photoreal iPhone bezel,
  and your own logo watermarked in.
- **What you see is what exports** — the preview and the encoder share the same
  math, verified frame by frame.
- **Share links, built in** — public or private, flip it any time.
- **Know who watched** — views, drop-off, and clicks per video in your
  dashboard.
- **Timestamped comments** — viewers leave feedback pinned to the exact second.
- **Native the whole way down** — Swift, Metal, and AppKit. No web view.

## The full feature list

Everything the app ships today, grouped:

${FEATURE_INVENTORY_MARKDOWN}

## Your AI agent can do this too

CaptureCat ships a Model Context Protocol (MCP) server inside the app. Claude,
ChatGPT, Cursor, Copilot, or Windsurf can read where you clicked, add the zooms
for you, restyle the frame, and export the final video with the same engine the
editor uses. See [Agents & MCP](${SITE_URL}/agents).

[Download for Mac](${SITE_URL}/download) · [Pricing](${SITE_URL}/pricing) · [Agents & MCP](${SITE_URL}/agents)
`,
  },
  {
    path: "/pricing",
    title: "Pricing",
    description:
      "CaptureCat pricing — a free Mac screen recorder with a Pro plan for cloud sharing, comments, and viewer analytics. Prices come live from Stripe.",
    lastModified: "2026-08-05",
    markdown: `# CaptureCat Pricing

The recorder and editor are free. Pro adds sharing, comments, and analytics.
Live prices come from Stripe on the [pricing page](${SITE_URL}/pricing).

## Free — $0 forever

The full editor, on your Mac.

- Unlimited screen recordings
- Auto zoom & motion effects
- Camera overlay & cursor smoothing
- On-device captions
- Export in full quality

## CaptureCat Pro

Everything in Free, plus:

- Cloud sharing with links
- Timestamped viewer comments
- Views, drop-off & click analytics
- Upload screenshots & images
- Capture web pages by URL
- Watermark-free exports
- Priority support

Monthly and annual billing are both available; the annual plan is discounted.
`,
  },
  {
    path: "/agents",
    title: "Agents & MCP",
    description:
      "CaptureCat ships a built-in MCP server: let Claude, ChatGPT, Cursor, Copilot, or Windsurf inspect your recordings, add zooms, restyle projects, and export.",
    lastModified: "2026-08-05",
    markdown: `# Agents & MCP

CaptureCat ships a Model Context Protocol (MCP) server inside the app — no
plugin, no sidecar. \`CaptureCat --mcp\` speaks MCP over stdio. Tell Claude,
ChatGPT, Cursor, Copilot, or Windsurf to add zooms where you clicked, restyle a
project, and export the final video.

## Tools

- \`list_projects\` — every recording in your library.
- \`describe_project\` — the full timeline plus an interaction digest (click
  clusters and idle spans) so the agent knows where zooms belong.
- \`add_effect\` — add zoom, tilt, or zoom-tilt effects to a time range.
- \`set_style\` — change wallpaper, padding, shadows, and other validated
  settings.
- \`export_project\` — render the final video with the real export engine.

## Install

The server is the app binary itself. Install CaptureCat, then register it:

\`\`\`sh
# Claude Code
claude mcp add capturecat -- /Applications/CaptureCat.app/Contents/MacOS/CaptureCat --mcp

# OpenAI Codex
codex mcp add capturecat -- /Applications/CaptureCat.app/Contents/MacOS/CaptureCat --mcp
\`\`\`

For Claude Desktop, Cursor, GitHub Copilot, and Windsurf, add a \`capturecat\`
entry to the client's MCP config pointing \`command\` at the binary with
\`args: ["--mcp"]\`. Full snippets are on the [Agents page](${SITE_URL}/agents).
`,
  },
  {
    path: "/download",
    title: "Download CaptureCat for macOS",
    description:
      "Download CaptureCat, the native screen recorder for macOS. Free to use, with a Pro plan for sharing and analytics.",
    lastModified: "2026-08-05",
    markdown: `# Download CaptureCat for macOS

CaptureCat is a native macOS app. Download the latest release, drag it to
Applications, and record your first clip — the editing happens automatically.

Get the newest build from the [download page](${SITE_URL}/download). The app is
free to use; a Pro subscription unlocks cloud sharing, comments, and analytics.
`,
  },
  {
    path: "/privacy",
    title: "Privacy Policy",
    description:
      "How CaptureCat handles your data: recordings stay on your Mac unless you share them, captions are transcribed on device, and we collect only what billing and sharing need.",
    lastModified: "2026-08-05",
    markdown: `# Privacy Policy

_Last updated: 5 August 2026._ This policy complies with UK GDPR and the Data
Protection Act 2018.

**Who we are.** CaptureCat is operated by a UK-based sole trader trading as
"CaptureCat", the data controller for your personal data. Contact:
contact@capturecat.so.

**Data we collect.**

- **Account** — name, email, and avatar from Google or Apple sign-in (never your
  password).
- **Billing** — handled by Stripe; we receive subscription status and limited
  metadata, never full card numbers.
- **Content you upload** — recordings/images you choose to share. Recordings you
  don't upload never leave your Mac.
- **Viewer analytics** — aggregate view counts, watch drop-off, and player
  interactions for a video's owner, keyed to a random per-tab id, not a cookie.
- **Technical** — IP and request metadata for security and rate limiting.

**Lawful bases.** Contract (providing the service and taking payment),
legitimate interests (security and abuse prevention), and legal obligation (tax
records).

**Sharing.** We don't sell your data. Processors: Cloudflare (hosting, storage,
database), Stripe (payments), Google and Apple (sign-in). International transfers
are protected by the UK IDTA / UK Addendum to the SCCs or an adequacy decision.

**Retention.** Account data is kept while your account is open and deleted within
30 days of closure, except records we must keep by law (e.g. tax records, six
years).

**Your rights.** Access, rectification, erasure, restriction, objection,
portability, and withdrawing consent. Email contact@capturecat.so. You may also
complain to the ICO (ico.org.uk).

**Cookies.** One essential sign-in cookie; no advertising or tracking cookies.

Questions? Email contact@capturecat.so.
`,
  },
  {
    path: "/terms",
    title: "Terms of Service",
    description:
      "The terms that govern your use of the CaptureCat app, share links, and Pro subscription.",
    lastModified: "2026-08-05",
    markdown: `# Terms of Service

_Last updated: 5 August 2026._ Governed by the laws of England and Wales.

**Who we are.** CaptureCat is operated by a UK-based sole trader trading as
"CaptureCat". Contact: contact@capturecat.so. These terms are a binding agreement
governing the macOS app, capturecat.so, and app.capturecat.so.

**Your account.** Sign in with Google or Apple; you're responsible for activity
under your account and must be at least 13.

**Licence.** A personal, non-exclusive, non-transferable licence to use the app
on Macs you control. No reselling or reverse engineering except as the law
allows.

**Your content.** You own your recordings and uploads. You grant us only the
licence needed to host and deliver videos you share; it ends when you delete them
or close your account. Don't upload unlawful, infringing, or harmful content.

**Subscriptions.** Pro is billed via Stripe monthly or annually and renews until
cancelled. Cancel any time; access runs to the end of the paid period.

**Cancellation & refunds.** You have a 14-day right to cancel under the Consumer
Contracts Regulations 2013, but by starting to use paid features you ask us to
begin supply immediately and lose that right for features already provided.
Nothing affects your statutory rights under the Consumer Rights Act 2015
(satisfactory quality, fit for purpose, as described).

**Availability & liability.** Online features are provided on a reasonable-efforts
basis. We don't limit liability where unlawful (death/personal injury from
negligence, fraud, or your consumer rights); otherwise liability is capped at what
you paid us in the prior 12 months. Keep local copies — exports never depend on
us.

**Governing law.** England and Wales.

Questions? Email contact@capturecat.so.
`,
  },
];

/**
 * Every public page: the hand-written marketing pages plus the generated
 * comparison/alternative (pSEO) pages. Everything downstream — sitemap,
 * llms.txt, robots, /*.md twins, Link: alternate headers — reads this list.
 */
export const SITE_PAGES: SitePage[] = [...STATIC_PAGES, ...PSEO_SITE_PAGES];

export function findPageByPath(path: string): SitePage | undefined {
  const normalized = path === "" ? "/" : path;
  return SITE_PAGES.find((p) => p.path === normalized);
}

/** The relative Markdown URL for a page path, e.g. "/pricing" → "/pricing.md". */
export function markdownHref(path: string): string {
  return path === "/" ? "/index.md" : `${path}.md`;
}

/**
 * Head link descriptors advertising the Markdown alternate and canonical URL.
 * Spread into a route's `head: () => ({ links })` so agents can discover the
 * Markdown rendering via `<link rel="alternate" type="text/markdown">`.
 */
export function markdownAlternateLinks(
  path: string
): Array<{ rel: string; href: string; type?: string }> {
  return [
    { rel: "canonical", href: `${SITE_URL}${path === "/" ? "" : path}` },
    { rel: "alternate", type: "text/markdown", href: markdownHref(path) },
  ];
}
