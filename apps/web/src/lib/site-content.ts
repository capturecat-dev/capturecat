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
    title: "CaptureCat: the Mac screen recorder that edits itself",
    description:
      "CaptureCat records your Mac and adds the zooms, cursor smoothing, and captions automatically. Native Swift, free to record and export, with share links and viewer analytics on Pro.",
    lastModified: "2026-09-02",
    markdown: `# CaptureCat: record your screen, skip the editing

CaptureCat is a Mac screen recorder that watches where you click and type,
then adds the zooms, smooths the cursor, and writes the captions for you. What
you see in the preview is what you get in the file.

Free to record and export. Open source under the AGPL-3.0 at
https://github.com/capturecat-dev/capturecat. Native Swift, no Electron.
macOS 14 or later.

## How a recording becomes a video

1. **Pick what to record.** A display, a window, a dragged area, an iPhone over
   USB, or a web page by URL. Camera bubble and mic are optional.
2. **Stop, and the edit is waiting.** Every click, keystroke, and scroll is
   stored as data during the recording. When you stop, CaptureCat places zoom
   blocks where you were working. Tight click clusters get a deeper push in,
   typing extends the hold.
3. **Change anything on the preview.** Wallpaper, padding, shadow, device
   frame, cursor style, captions. Every automatic zoom is a normal block on
   the timeline you can move, resize, or delete.
4. **Export a file or send a link.** MP4 or MOV up to 4K 60 fps with the same
   maths in the encoder as in the preview, or upload from the app and copy a
   share link with comments and viewer analytics.

## Headline features

- **Auto zoom.** Zooms are placed from your recorded clicks, not a fixed rule.
  0.3x to 6x, draggable focal point, five animation styles, follow cursor mode.
- **Cursor.** The raw pointer path is replaced with a damped spring. The
  hotspot never leaves the pixel it was recorded over. Ripples and click sounds
  are optional.
- **Captions.** Transcribed on your Mac. Six presets, karaoke word
  highlighting, editable segments, placed wherever you drag them.
- **Framing.** Gradients, macOS wallpapers, your own image, or transparent.
  Rounded, squircle, or square frames. Photoreal iPhone and iPad bezels.
  Aspect ratios from 16:9 to 9:16.
- **Camera bubble.** Recorded as its own track. Move, reshape, or hide it after
  the fact. Name tag pill. Per span layouts.
- **Focus and privacy.** Blur or pixelate regions with feathered edges.
  Spotlights that dim everything else. Depth focus.
- **Timeline.** Five lanes, trim, split, cut, speed regions, annotations,
  narration, full undo.
- **Share links (Pro).** Upload from the app. Public or private. Comments
  pinned to the second. Views, watch time, and retention per video.

## The full feature list

${FEATURE_INVENTORY_MARKDOWN}

## Your AI agent can drive it

CaptureCat ships a Model Context Protocol (MCP) server inside the app binary.
Claude Code, Codex, Cursor, Copilot, or Windsurf can start a recording, read
where you clicked, add the zooms, restyle the frame, render frames to check
their work, and export with the same engine the editor uses. See
[Agents and MCP](${SITE_URL}/agents).

## Questions

- **Is it free?** Yes. Recording, the editor, auto zoom, captions, and full
  quality export are free with no time limit and no resolution cap. Pro is only for
  share links, comments, and analytics.
- **Does audio leave my Mac for captions?** No. Transcription runs on device.
- **Will the export match the preview?** Yes. The preview and the encoder
  share one set of maths and are compared frame by frame before every release.
- **Which Macs?** macOS 14 Sonoma or later, Apple Silicon and Intel builds.
- **Is it Electron?** No. Swift, AppKit, and Metal.
- **Is it open source?** Yes. The Mac app, the API, and the website are in one
  public repository under the AGPL-3.0. Build it yourself or self host the
  sharing side.

[Download for Mac](${SITE_URL}/download) · [Features](${SITE_URL}/features) · [Pricing](${SITE_URL}/pricing) · [Agents and MCP](${SITE_URL}/agents)
`,
  },
  {
    path: "/features",
    title: "Features",
    description:
      "Every feature in CaptureCat, the Mac screen recorder: recording sources, auto zoom, cursor smoothing, captions, device frames, camera bubble, blur and spotlight, timeline, export, sharing, library search, and the MCP server for AI agents.",
    lastModified: "2026-09-02",
    markdown: `# CaptureCat features

Everything the app does today, on one page. Nothing here is planned or in
beta.

## Beyond the headline features

- **Record an iPhone or iPad.** Connect over USB and it appears as a source.
  Exports wrap it in a photoreal bezel for that model. Taps are recorded as
  data so tap indicators can be styled afterwards.
- **Capture a web page by URL.** Desktop, tablet, or mobile viewport, full
  page height, optional dark mode, cookie banners and chat widgets removed.
- **Annotations.** Text, arrows, callouts, shapes, freehand drawing, and
  looping tap indicators, each with build in and build out animations.
- **Keystroke overlay.** Shortcuts appear as a pill in the frame as you press
  them. Toggle with Command Shift S. Off by default.
- **Library search.** Every capture is indexed with on device OCR. Command K
  finds text inside recordings and jumps to the frame.
- **Export.** MP4 or MOV up to 4K 60 fps, live bitrate and file size estimate,
  fast export for much smaller files on static screens.

## The complete inventory

${FEATURE_INVENTORY_MARKDOWN}

[Download for Mac](${SITE_URL}/download) · [Pricing](${SITE_URL}/pricing)
`,
  },
  {
    path: "/pricing",
    title: "Pricing",
    description:
      "CaptureCat is free to record, edit, and export. Pro adds share links, timestamped comments, and viewer analytics. Prices come live from Stripe.",
    lastModified: "2026-09-02",
    markdown: `# CaptureCat pricing

The recorder is free. Pay for the link. Everything that runs on your Mac costs
nothing, forever. Pro is the hosted part: share pages, comments, and
analytics. Live prices are on the [pricing page](${SITE_URL}/pricing).

## Free, $0 forever

The full app, on your Mac.

- Unlimited screen recordings
- Auto zoom and motion effects
- Camera overlay and cursor smoothing
- On device captions
- Export in full quality

## CaptureCat Pro

Everything in Free, plus:

- Cloud sharing with public or private links
- Timestamped viewer comments
- Views, watch time, retention, and click analytics
- Upload screenshots and images
- Capture web pages by URL
- Priority support

Monthly and annual billing are both available. The annual plan is discounted.
Cancel from the billing page. Local recordings and exports are never affected
by the subscription.

## Questions

- **What is free?** Recording, the editor, every effect, and export. No time
  limit, no resolution cap.
- **What is Pro for?** Share links, comments, analytics, and web capture.
- **What happens to shared videos if I stop paying?** Links stop serving.
  Nothing on your Mac is touched. Resubscribe and the same links come back.
- **Team plan?** Not yet. Email contact@capturecat.so with the seat count.
`,
  },
  {
    path: "/agents",
    title: "Agents and MCP",
    description:
      "CaptureCat has a built in MCP server. Let Claude, Codex, Cursor, Copilot, or Windsurf record, inspect, edit, restyle, and export your recordings.",
    lastModified: "2026-09-02",
    markdown: `# Agents and MCP

CaptureCat ships a Model Context Protocol (MCP) server inside the app binary.
No plugin, no sidecar. \`CaptureCat --mcp\` speaks MCP over stdio. Tell Claude
Code, Codex, Cursor, Copilot, or Windsurf what you want and it uses the same
engine as the editor.

## Tools (17)

Record and find: \`list_capture_targets\`, \`start_recording\`,
\`stop_recording\`, \`list_projects\`, \`search_captures\`, \`list_notes\`.

Read and edit: \`describe_project\` (timeline plus click clusters and idle
spans), \`get_transcript\`, \`auto_zoom\`, \`add_effect\`, \`update_effect\`,
\`remove_effect\`, \`add_annotation\`, \`remove_annotation\`, \`cut_video\`,
\`set_style\`.

Check and export: \`render_frames\` (so the agent can look at its own edits),
\`export_project\`.

Edits are written atomically with a backup. Media files are never touched.
Invalid edits are refused with a readable error.

## Install

Easiest: open CaptureCat, click the menu bar icon, choose Connect AI Agents,
and pick your client. The app writes the config itself.

By hand:

\`\`\`sh
# Claude Code
claude mcp add capturecat -- /Applications/CaptureCat.app/Contents/MacOS/CaptureCat --mcp

# OpenAI Codex
codex mcp add capturecat -- /Applications/CaptureCat.app/Contents/MacOS/CaptureCat --mcp
\`\`\`

For Claude Desktop, Cursor, GitHub Copilot, and Windsurf, add a \`capturecat\`
entry to the client's MCP config pointing \`command\` at the binary with
\`args: ["--mcp"]\`. Full snippets are on the [Agents page](${SITE_URL}/agents).

Close a project in the editor before letting an agent edit it. The editor
autosaves and would overwrite the agent's changes.
`,
  },
  {
    path: "/download",
    title: "Download CaptureCat for macOS",
    description:
      "Download CaptureCat, the free native screen recorder for macOS 14 and later. Builds for Apple Silicon and Intel. No account needed to record.",
    lastModified: "2026-09-02",
    markdown: `# Download CaptureCat for macOS

Free to record, edit, and export. No account needed until you want a share
link. Builds for Apple Silicon and Intel, macOS 14 Sonoma or later.

Get the latest build from the [download page](${SITE_URL}/download).

## After the download

1. Open the disk image and drag the app to Applications.
2. Allow Screen Recording when macOS asks. Microphone and Camera only if you
   turn those sources on.
3. Record from the menu bar icon or the global shortcut. The editor opens with
   the auto edit already applied.
4. Export, or sign in with Google or Apple inside the app to upload and share.

The app updates itself. Recordings are ordinary project folders on disk and
stay where they are if you uninstall.
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

- **Account:** name, email, and avatar from Google or Apple sign-in (never your
  password).
- **Billing:** handled by Stripe. We receive subscription status and limited
  metadata, never full card numbers.
- **Content you upload:** recordings and images you choose to share. Recordings
  you do not upload never leave your Mac.
- **Viewer analytics:** aggregate view counts, watch drop-off, and player
  interactions for a video's owner, keyed to a random per-tab id, not a cookie.
- **Technical:** IP and request metadata for security and rate limiting.

**Lawful bases.** Contract (providing the service and taking payment),
legitimate interests (security and abuse prevention), and legal obligation (tax
records).

**Sharing.** We do not sell your data. Processors: Cloudflare (hosting, storage,
database), Stripe (payments), Google and Apple (sign-in). International transfers
are protected by the UK IDTA / UK Addendum to the SCCs or an adequacy decision.

**Retention.** Account data is kept while your account is open and deleted within
30 days of closure, except records we must keep by law (e.g. tax records, six
years).

**Your rights.** Access, rectification, erasure, restriction, objection,
portability, and withdrawing consent. Email contact@capturecat.so. You may also
complain to the ICO (ico.org.uk).

**Cookies.** One essential sign-in cookie. No advertising or tracking cookies.

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

**Your account.** Sign in with Google or Apple. You are responsible for activity
under your account and must be at least 13.

**Licence.** A personal, non-exclusive, non-transferable licence to use the app
on Macs you control. No reselling or reverse engineering except as the law
allows.

**Your content.** You own your recordings and uploads. You grant us only the
licence needed to host and deliver videos you share. It ends when you delete them
or close your account. Do not upload unlawful, infringing, or harmful content.

**Subscriptions.** Pro is billed via Stripe monthly or annually and renews until
cancelled. Cancel any time. Access runs to the end of the paid period.

**Cancellation and refunds.** You have a 14-day right to cancel under the Consumer
Contracts Regulations 2013, but by starting to use paid features you ask us to
begin supply immediately and lose that right for features already provided.
Nothing affects your statutory rights under the Consumer Rights Act 2015
(satisfactory quality, fit for purpose, as described).

**Availability and liability.** Online features are provided on a reasonable-efforts
basis. We do not limit liability where unlawful (death or personal injury from
negligence, fraud, or your consumer rights). Otherwise liability is capped at what
you paid us in the prior 12 months. Keep local copies. Exports never depend on
us.

**Governing law.** England and Wales.

Questions? Email contact@capturecat.so.
`,
  },
];

/**
 * Every public page: the hand-written marketing pages plus the generated
 * comparison/alternative (pSEO) pages. Everything downstream (sitemap,
 * llms.txt, robots, /*.md twins, Link: alternate headers) reads this list.
 */
export const SITE_PAGES: SitePage[] = [...STATIC_PAGES, ...PSEO_SITE_PAGES];

export function findPageByPath(path: string): SitePage | undefined {
  const normalized = path === "" ? "/" : path;
  return SITE_PAGES.find((p) => p.path === normalized);
}

/** The relative Markdown URL for a page path, e.g. "/pricing" becomes "/pricing.md". */
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
