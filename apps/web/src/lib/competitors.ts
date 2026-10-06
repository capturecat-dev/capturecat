import type { Competitor } from "./pseo-content";

/**
 * Every competitor on /compare and /alternatives, generated from sourced
 * research and reviewed by hand. Checked against each product's own site on
 * FACTS_CHECKED (pseo-content.ts). `features` cells align 1:1 with
 * FEATURE_ROWS: auto zoom, cursor, captions, MCP, share analytics, free tier,
 * open source, platform, price. null means unverified ("check their site").
 *
 * When a fact changes, change the cell AND its source, and bump FACTS_CHECKED.
 */
export const COMPETITORS: Competitor[] = [
  {
    "slug": "screen-studio",
    "name": "Screen Studio",
    "website": "https://screen.studio",
    "category": "demo",
    "summary": "Screen Studio is a Mac screen recorder and editor that automatically adds animated zooms, smooths the cursor and frames recordings for demos and tutorials.",
    "differentiator": "Screen Studio and CaptureCat both offer automatic zoom from clicks, cursor smoothing with click effects and on-device captions. CaptureCat includes those in a free tier with no watermark and 4K 60 fps export, is open source under AGPL-3.0, ships a built-in MCP server for coding agents, and has a browser app for Windows and Linux users.",
    "pickThemWhen": "you want a polished, Mac-only recorder with automatic click zooms and you are happy to pay a subscription for it.",
    "strengths": [
      "Automatic zoom generated from where you clicked, with Classic and Loupe zoom styles",
      "Transcription and captions run locally (Whisper or Apple speech), with edit-by-transcript",
      "Shareable links with timestamped comments and view counts, plus 4K 60 fps MP4 export"
    ],
    "tradeoffs": [
      "Mac only; its FAQ says there are no near-future plans for Windows",
      "Subscription only for new buyers ($29/mo or $108/yr); one-time licenses are no longer sold",
      "Without an active plan you can use the editor but cannot export video files"
    ],
    "features": [
      true,
      true,
      true,
      false,
      "Share links with view counts",
      "Free to try; export needs a plan",
      false,
      "macOS",
      "$29/mo or $108/yr ($9/mo)"
    ],
    "switchTip": "Install CaptureCat next to Screen Studio and record your next demo in it; automatic zoom from recorded clicks and cursor smoothing work on the free tier. Finish any open Screen Studio projects there before you cancel, since your export access ends with the plan.",
    "faqExtra": {
      "question": "Does Screen Studio work on Windows?",
      "answer": "No. Screen Studio is macOS only, and its FAQ says there are no near-future plans to add Windows support."
    },
    "sources": [
      "https://screen.studio/",
      "https://screen.studio/guide/auto-zoom",
      "https://screen.studio/download",
      "https://trainn.co/blog/screen-studio-pricing/"
    ]
  },
  {
    "slug": "focusee",
    "name": "FocuSee",
    "website": "https://focusee.imobie.com",
    "category": "demo",
    "summary": "FocuSee is a screen recorder for macOS and Windows from iMobie that applies automatic zoom, cursor effects and AI editing tools to screen recordings.",
    "differentiator": "CaptureCat's free tier includes unlimited exports up to 4K 60 fps with no watermark, automatic zoom from clicks, cursor smoothing and on-device English captions, where FocuSee's free trial exports one video. FocuSee runs natively on Windows and records Android devices, which CaptureCat does not; both record iPhone over USB, and CaptureCat adds an open-source AGPL codebase and a built-in MCP server.",
    "pickThemWhen": "you want one auto-zoom recorder licence that covers both Mac and Windows and you will use AI extras like avatars or filler-word removal.",
    "strengths": [
      "Automatic zoom follows both clicks and typing, with 3D motion and tilt effects",
      "Runs on Mac and Windows, and records iOS and Android devices over USB",
      "Broad AI toolset: subtitles in 55+ languages, filler-word removal, AI avatars, webcam background removal"
    ],
    "tradeoffs": [
      "Free trial allows only one exported video",
      "Many AI features consume credits; the Standard plan includes no AI credits",
      "Lifetime license covers version 2.x only; the next major version costs extra"
    ],
    "features": [
      true,
      true,
      "Yes; on-device vs cloud not stated",
      false,
      "Share links, no analytics listed",
      "Free trial, one 4K export",
      false,
      "macOS & Windows",
      "$19.99/mo or $49.99/yr; $199.99 once"
    ],
    "switchTip": "Export finished FocuSee projects as MP4 before switching, since CaptureCat cannot open FocuSee project files. New recordings in CaptureCat get automatic zoom from clicks without any setup.",
    "faqExtra": {
      "question": "Is FocuSee free?",
      "answer": "FocuSee offers a free trial that lets you try standard features and export one video in up to 4K. Ongoing use needs a subscription or lifetime licence, and some AI features also need credits."
    },
    "sources": [
      "https://focusee.imobie.com/",
      "https://focusee.imobie.com/pricing.htm?os=mac",
      "https://alternativeto.net/news/2024/12/imobie-acquires-screen-recording-and-video-edit-platform-focusee"
    ]
  },
  {
    "slug": "rapidemo",
    "name": "Rapidemo",
    "website": "https://getrapidemo.com",
    "category": "demo",
    "summary": "Rapidemo is a Windows 10 and 11 screen recorder that adds automatic click zooms, cursor smoothing, animated layouts and subtitles to recordings.",
    "differentiator": "Rapidemo is Windows-only, while CaptureCat is a native macOS app with a browser app for Windows users. Both add automatic zoom from clicks, cursor smoothing and captions generated locally; CaptureCat exports for free without a licence and adds an MCP server, viewer analytics on Pro share links, and an AGPL open-source codebase.",
    "pickThemWhen": "you record on Windows and want Screen Studio-style automatic zooms and cursor polish in a desktop app.",
    "strengths": [
      "Automatic zoom on clicks plus smoothed, vector-redrawn cursors",
      "Recording, editing and subtitle generation all run locally",
      "2D and 3D animated camera layouts and multi-aspect-ratio export up to 4K 60 fps"
    ],
    "tradeoffs": [
      "Windows only; no macOS or Linux version",
      "Exporting requires a paid licence",
      "Lifetime licence includes one year of updates; renewals cost $99"
    ],
    "features": [
      true,
      true,
      true,
      false,
      "Share links, no analytics listed",
      "Free trial; export needs a license",
      false,
      "Windows only",
      "$19/mo, $9/mo yearly, or $199 once"
    ],
    "switchTip": "Rapidemo projects cannot be opened in CaptureCat, so export finished videos as MP4 first. On Windows, use CaptureCat's browser app; on a Mac, use the native app.",
    "faqExtra": {
      "question": "Is Rapidemo available for Mac?",
      "answer": "No. Rapidemo is built for Windows 10 and 11. Its FAQ says macOS and Linux support is under evaluation with no committed timeline."
    },
    "sources": [
      "https://getrapidemo.com/",
      "https://www.screensnap.pro/blog/screen-studio-for-windows"
    ]
  },
  {
    "slug": "screen-charm",
    "name": "Screen Charm",
    "website": "https://screencharm.com",
    "category": "demo",
    "summary": "Screen Charm is a macOS screen recorder and editor that applies automatic click zoom, cursor smoothing and backgrounds to product demos and tutorials.",
    "differentiator": "Both apps add automatic zoom from clicks, cursor smoothing, click ripples and captions on macOS. CaptureCat exports for free with no watermark, is a native Swift app (Screen Charm's changelog refers to Electron), is open source under AGPL-3.0, has a built-in MCP server, and offers viewer analytics on Pro share links.",
    "pickThemWhen": "you want a Mac auto-zoom recorder with a one-time price and built-in vertical exports for social clips.",
    "strengths": [
      "Automatic zoom after every click, plus cursor smoothing, click ripples and motion blur",
      "One-time $79 licence with free lifetime updates on up to 3 devices",
      "Split vertical export for Reels, Shorts and TikTok that follows the cursor"
    ],
    "tradeoffs": [
      "Exporting requires buying the licence",
      "macOS only",
      "Captions were added only in September 2026 (v1.11.4), so the feature is new"
    ],
    "features": [
      true,
      true,
      "Yes; on-device vs cloud not stated",
      false,
      "Share links, no analytics listed",
      "Free to record; export needs license",
      false,
      "macOS",
      "$79 one-time (3 devices)"
    ],
    "switchTip": "Export any Screen Charm projects you want to keep as MP4; CaptureCat cannot open Screen Charm projects. Your existing Screen Charm share links stay where they are.",
    "faqExtra": {
      "question": "Is Screen Charm free?",
      "answer": "Screen Charm is free to download and use for recording, with no time limit on the trial. Exporting the finished video requires a one-time $79 purchase."
    },
    "sources": [
      "https://screencharm.com/",
      "https://screencharm.com/changelog",
      "https://screencharm.com/what-is-screen-charm",
      "https://screencharm.com/pricing"
    ]
  },
  {
    "slug": "tella",
    "name": "Tella",
    "website": "https://www.tella.com",
    "category": "demo",
    "summary": "Tella is a subscription screen recorder with a browser-based editor, hosted share pages with viewer analytics, and desktop recorders for Mac and Windows.",
    "differentiator": "Tella matches CaptureCat on automatic zoom from clicks, cursor smoothing, share analytics and an official MCP server. CaptureCat differs by being free for recording, editing and 4K export, running captions on-device, editing locally in a native Mac app, and being open source; Tella has a native Windows app and team plans, which CaptureCat doesn't yet.",
    "pickThemWhen": "you want polished, hosted demo videos with team workspaces and detailed viewer analytics, and a per-seat subscription fits your budget.",
    "strengths": [
      "Auto Zoom generates zooms from recorded cursor clicks, with styles from Subtle to Intense, and can apply them automatically after recording.",
      "Share pages with detailed analytics: views, unique viewers, watch time, engagement, traffic sources and locations.",
      "Official MCP server for Claude, ChatGPT, Codex and Cursor, plus transcription in 106 languages."
    ],
    "tradeoffs": [
      "No free plan; after the 7-day trial you can't record, edit or export without a subscription.",
      "Editing happens in the web editor, so recordings are uploaded before you edit.",
      "The animated cursor (smoothing, click effects) only works for Mac and Windows app recordings, and 60 fps export is Premium-only."
    ],
    "features": [
      true,
      true,
      "Auto-captions (location not stated)",
      "Official MCP for editing & publishing",
      true,
      "7-day free trial, no free plan",
      false,
      "Mac & Windows apps, browser",
      "From $13/user/mo yearly ($26 monthly)"
    ],
    "switchTip": "Download your Tella videos (and SRT subtitles if you need them) before your subscription ends, since recording, editing and exporting stop when it lapses. Re-record or import the MP4s into CaptureCat, and move share links over only for videos people still watch.",
    "faqExtra": {
      "question": "Does Tella have a free plan?",
      "answer": "No. New Tella workspaces get a 7-day free trial, which owners can extend once by another 7 days. After that, Pro costs $26 per user per month, or $13 per user per month billed yearly."
    },
    "sources": [
      "https://www.tella.com/pricing",
      "https://www.tella.com/docs/help/editing/add-a-zoom.md",
      "https://www.tella.com/docs/_llms/help-center.md",
      "https://www.tella.com/mcp",
      "https://www.tella.com/help/billing/understanding-your-bill.md"
    ]
  },
  {
    "slug": "cursorful",
    "name": "Cursorful",
    "website": "https://cursorful.com",
    "category": "demo",
    "summary": "Cursorful is a screen recorder with automatic click zooms, available as a free Chrome extension and as Pro desktop apps for macOS and Windows.",
    "differentiator": "Like Cursorful, CaptureCat offers free automatic zoom from clicks, cursor smoothing with click effects and on-device captions. CaptureCat's free tier allows commercial use, records any app with mic and camera, and exports up to 4K, which Cursorful reserves for Pro; CaptureCat is also open source (AGPL-3.0), has a built-in MCP server and viewer analytics on Pro share links.",
    "pickThemWhen": "you mostly demo web apps in Chrome and want free auto-zoom with no sign-up, or a one-time Pro licence for Mac and Windows.",
    "strengths": [
      "Free extension with no sign-up, no watermark and unlimited exports",
      "Local rendering and on-device captions and mic denoising; cloud is opt-in",
      "Pro desktop apps redraw the cursor with smoothing, motion blur, sway and click animations"
    ],
    "tradeoffs": [
      "Free plan is non-commercial and records the browser only, without mic or camera",
      "In the extension, auto-zoom stops working when a non-browser app is in focus",
      "Auto-zoom triggers only after two or more clicks within 3 seconds, by design"
    ],
    "features": [
      true,
      true,
      true,
      false,
      "Share links, no analytics listed",
      "Free, browser only, non-commercial",
      false,
      "Chrome ext + Mac/Win apps (Pro)",
      "Free · Pro $79 one-time per seat"
    ],
    "switchTip": "Export finished Cursorful projects as MP4 before switching. If you used the Chrome extension on Windows or Linux, CaptureCat's browser app runs in Chrome and Edge 113+.",
    "faqExtra": {
      "question": "Does Cursorful auto-zoom outside the browser?",
      "answer": "Only with the Pro desktop apps. The Chrome extension cannot see clicks outside the browser, so auto-zoom stops when another app is in focus, though you can add fixed zooms in the editor afterwards."
    },
    "sources": [
      "https://cursorful.com/"
    ]
  },
  {
    "slug": "canvid",
    "name": "CANVID",
    "website": "https://www.canvid.com",
    "category": "demo",
    "summary": "CANVID is a screen recorder for Windows and Mac that turns clicks into automatic zooms and adds AI tools for captions, voice cleanup and webcam effects.",
    "differentiator": "CaptureCat exports for free, works offline, and generates English captions on-device on the Mac, where CANVID transcribes in the cloud. CANVID runs natively on Windows and supports 99 transcription languages; CaptureCat is open source (AGPL-3.0), has a built-in MCP server and shows viewer analytics on Pro share links.",
    "pickThemWhen": "you need the same auto-zoom recorder on Windows and Mac and want AI fixes like speech correction or a generated webcam.",
    "strengths": [
      "Automatic zoom on every click, with cursor smoothing and styling",
      "AI Speech Edit fixes spoken mistakes from the transcript, and AI Webcam can generate a lip-synced camera track",
      "Transcription in 99 languages, with on-device processing on supported Windows hardware"
    ],
    "tradeoffs": [
      "Needs an internet connection to sign in and run; no offline mode yet",
      "Exporting and Quick Share links require a paid licence",
      "On Mac, transcription runs in the cloud only"
    ],
    "features": [
      true,
      true,
      "Cloud on Mac; local option on Windows",
      false,
      "Share links, no analytics listed",
      "Free to try; export needs a license",
      false,
      "Windows & macOS",
      "$84/yr (Pro) or $75 one-time"
    ],
    "switchTip": "Export CANVID projects as MP4 before cancelling, and download anything stored in CANVID Cloud that you want to keep. CaptureCat cannot import CANVID projects.",
    "faqExtra": {
      "question": "Does CANVID work offline?",
      "answer": "Not currently. CANVID's FAQ says you need an internet connection to sign in and run the app, and that an offline mode is being tested but is not in the current release."
    },
    "sources": [
      "https://www.canvid.com/",
      "https://www.canvid.com/features",
      "https://www.canvid.com/support/editing/captions-and-transcription",
      "https://www.canvid.com/ai",
      "https://canvid.com/support/canvid-gallery-managing-sharing-your-cloud-recordings",
      "https://www.canvid.com/support/export-and-sharing/quick-share",
      "https://www.canvid.com/pricing",
      "https://www.canvid.com/changelog",
      "https://www.capterra.com/p/10021346/Canvid/"
    ]
  },
  {
    "slug": "recordly",
    "name": "Recordly",
    "website": "https://recordly.dev",
    "category": "demo",
    "summary": "Recordly is a free, open-source desktop screen recorder and editor for macOS, Windows and Linux with auto-zoom, cursor polish and styled backgrounds.",
    "differentiator": "Recordly matches CaptureCat on being free and AGPL-licensed, with auto-zoom, cursor smoothing and local captions. CaptureCat is a native Swift/Metal Mac app rather than Electron, records iPhone and iPad over USB, has a built-in MCP server, and offers Pro share links with viewer analytics; Recordly has native Windows and Linux builds, where CaptureCat offers a browser app instead.",
    "pickThemWhen": "you want a free, open-source auto-zoom recorder that also runs natively on Windows and Linux.",
    "strengths": [
      "Free and open source, with no paywalls, on macOS, Windows and Linux",
      "Cursor smoothing, motion blur, click bounce, sway and cursor loop for GIFs",
      "Community extension marketplace for click sounds, device frames and more"
    ],
    "tradeoffs": [
      "No hosted share links; you export MP4 or GIF files",
      "Electron app; Linux recording uses Electron capture and cannot hide the cursor",
      "Support is via GitHub issues rather than a paid support team"
    ],
    "features": [
      true,
      true,
      true,
      false,
      false,
      "Fully free",
      true,
      "macOS, Windows & Linux",
      "Free"
    ],
    "switchTip": "Recordly saves .recordly project files that CaptureCat cannot open, so export finished videos as MP4 first. On a Mac, CaptureCat's free tier covers the same auto-zoom, cursor and caption workflow.",
    "faqExtra": {
      "question": "Is Recordly related to OpenScreen?",
      "answer": "Yes. Recordly's licence file says it started as a fork of the OpenScreen project. OpenScreen's GitHub repository is now archived, while Recordly is actively developed."
    },
    "sources": [
      "https://recordly.dev/",
      "https://github.com/webadderallorg/Recordly",
      "https://github.com/webadderallorg/Recordly/releases",
      "https://github.com/webadderallorg/Recordly/blob/main/electron/ipc/captions/whisper.ts",
      "https://github.com/webadderallorg/Recordly/blob/main/LICENSE.md",
      "https://github.com/siddharthvaddem/openscreen",
      "https://github.com/syi0808/screenize"
    ]
  },
  {
    "slug": "loom",
    "name": "Loom",
    "website": "https://www.loom.com",
    "category": "async",
    "summary": "Loom is an Atlassian-owned async video messaging tool that records screen and camera and turns each recording into a hosted share link.",
    "differentiator": "Loom is cloud-first and built for teams, with analytics on every plan and admin controls; CaptureCat has no team plan yet. CaptureCat is a local editor whose free tier has no recording limit and includes automatic zoom from clicks, cursor smoothing and on-device captions, with share links, viewer analytics and timestamped comments on Pro.",
    "pickThemWhen": "your team mainly sends quick async video messages and wants hosted links, viewer insights and Atlassian integrations out of the box.",
    "strengths": [
      "Instant hosted share links with viewer insights on every plan, and engagement insights on paid plans",
      "Transcriptions and closed captions in 50+ languages, including on the free Starter plan",
      "Deep Atlassian, Slack and GitHub integrations, plus meeting recording and AI summaries on the AI tier"
    ],
    "tradeoffs": [
      "Free Starter plan caps you at 25 videos per person and 5 minutes per recording",
      "Editing AI (filler word removal, edit by transcript, summaries) needs Business + AI at $24/user/mo",
      "No automatic zoom yet; Loom's editing page lists auto-zoom as coming soon"
    ],
    "features": [
      "Listed as coming soon",
      "Click highlight while recording, paid",
      "Cloud auto-captions, all plans",
      "Via Atlassian MCP; no record/edit",
      true,
      "Free: 25 videos, 5-min limit",
      false,
      "Mac, Windows, Chrome, iOS, Android",
      "Free · from $15/user/mo billed yearly"
    ],
    "switchTip": "Keep Loom for links your team already relies on and record new demos and tutorials in CaptureCat, where the free tier does not cap recording length or count. If you need hosted links with views, watch time and retention, that is CaptureCat Pro.",
    "faqExtra": {
      "question": "Is Loom free?",
      "answer": "Loom's Starter plan is free, with up to 25 videos per person and a 5-minute limit per screen recording. Business costs $18/user/mo billed monthly or $180/user/yr."
    },
    "sources": [
      "https://www.atlassian.com/software/loom/editing",
      "https://jira.atlassian.com/browse/LOOM-406",
      "https://support.atlassian.com/loom/docs/highlight-your-mouse-clicks",
      "https://www.loom.com/pricing",
      "https://developer.atlassian.com/cloud/rovo-mcp/guides/supported-tools/",
      "https://www.businesswire.com/news/home/20231129694662/en/Atlassian-Completes-Acquisition-of-Loom",
      "https://support.atlassian.com/loom/docs/loom-ai-features/"
    ]
  },
  {
    "slug": "cap",
    "name": "Cap",
    "website": "https://cap.so",
    "category": "async",
    "summary": "Cap is an open-source screen recorder that combines Loom-style instant share links with a local Studio Mode editor, with desktop apps for macOS, Windows and Linux.",
    "differentiator": "Cap matches CaptureCat on several points: open source under AGPL, automatic zoom from clicks, cursor smoothing, on-device captions and an official MCP server (Cap's manages recordings, while CaptureCat's also records and edits). CaptureCat is a native Swift/AppKit/Metal Mac app that also records iPhone and iPad over USB and adds device bezels, spotlights and a keystroke overlay, while Cap has native Windows and Linux desktop apps and team workspaces, which CaptureCat does not offer yet.",
    "pickThemWhen": "you want an open-source recorder with native Windows and Linux apps, Loom-style instant links and team workspaces.",
    "strengths": [
      "Open source (AGPLv3) and self-hostable, with bring-your-own S3 or Google Drive storage",
      "Studio Mode editor with auto zoom from clicks, cursor smoothing and local Whisper/Parakeet captions",
      "Official MCP server (76 tools) and CLI so agents like Claude Code, Codex and Cursor can record and manage Caps"
    ],
    "tradeoffs": [
      "Free plan is for personal use only; commercial use needs the $29/yr or $58 lifetime Desktop License",
      "Cloud transcripts, AI summaries and viewer analytics require Cap Pro ($12/user/mo, or $8.16 billed yearly)",
      "Free and Desktop plans limit cloud share links to 5 minutes each (Desktop: 20 links a month)"
    ],
    "features": [
      true,
      true,
      true,
      "Official MCP; manages, no record/edit",
      "Yes, on Cap Pro",
      "Free for personal use, no watermark",
      true,
      "macOS, Windows & Linux",
      "Free · $29/yr desktop · Pro $12/user/mo"
    ],
    "switchTip": "Finish open Studio Mode edits in Cap, then start new recordings in CaptureCat; automatic zoom, cursor smoothing and on-device captions are on its free tier. If you use Cap's Windows or Linux desktop app, CaptureCat's option on those systems is its browser app.",
    "faqExtra": {
      "question": "Is Cap free for commercial use?",
      "answer": "No. Cap's free plan covers personal use; commercial use needs the Desktop License ($29/yr or $58 one-time) or Cap Pro."
    },
    "sources": [
      "https://cap.so/llms-full.txt",
      "https://cap.so/features/studio-mode",
      "https://cap.so/docs/recording/studio-mode",
      "https://cap.so/agents",
      "https://cap.so/llms.txt",
      "https://cap.so/pricing",
      "https://github.com/CapSoftware/Cap",
      "https://github.com/CapSoftware/Cap/releases"
    ]
  },
  {
    "slug": "zight",
    "name": "Zight",
    "website": "https://zight.com",
    "category": "async",
    "summary": "Zight, formerly CloudApp, is a screenshot, GIF and screen recording tool that uploads captures to share links for quick visual communication in teams.",
    "differentiator": "Zight's MCP server reads context from existing Zight links, while CaptureCat's built-in MCP server lets coding agents record, edit, render frames and export. CaptureCat also adds automatic zoom, cursor smoothing and on-device captions for free; Zight is stronger for screenshots, GIFs and team sharing.",
    "pickThemWhen": "your team shares lots of quick screenshots, GIFs and short clips and wants AI assistants to read the context behind those links.",
    "strengths": [
      "Screenshots, GIFs and video in one app with instant share links",
      "Official MCP server lets AI assistants read recordings, transcripts, OCR text and console logs behind a Zight link",
      "Desktop apps for Mac and Windows plus a Chrome extension and iOS app"
    ],
    "tradeoffs": [
      "Free plan limits recordings to 5 minutes and 1 GB of storage",
      "Transcription, captions and viewer analytics need a paid plan",
      "Editing is basic (trim, crop, merge); no automatic zoom"
    ],
    "features": [
      "Manual crop/zoom only",
      "Click highlights at record time",
      "Cloud, paid plans",
      "Official MCP, read-only",
      "Analytics on paid plans",
      "Free, 5-min limit, 1 GB storage",
      false,
      "macOS, Windows, Chrome extension, iOS",
      "Free · Create $9.95/user/mo, Collaborate $12/user/mo (annual)"
    ],
    "switchTip": "Keep Zight for screenshots and GIFs if you rely on them, and use CaptureCat for polished screen videos; download any Zight videos you want to re-edit as MP4 first.",
    "faqExtra": {
      "question": "Is Zight the same as CloudApp?",
      "answer": "Yes. CloudApp announced its rebrand to Zight in March 2023, and share links moved from share.getcloudapp.com to share.zight.com with automatic redirects."
    },
    "sources": [
      "https://zight.com/features/video-editing/",
      "https://zight.com/blog/edit-video-recordings",
      "https://support.zight.com/hc/en-us/articles/5824250433175-How-do-I-record-my-mouse-clicks-in-a-screen-recording-or-GIF-How-do-I-highlight-clicks",
      "https://zight.com/pricing/",
      "https://zight.com/mcp/",
      "https://zight.com/blog/zight-mcp-server-ai-visual-context/",
      "https://zight.com/blog/rebrand-faqs/"
    ]
  },
  {
    "slug": "vidyard",
    "name": "Vidyard",
    "website": "https://www.vidyard.com",
    "category": "async",
    "summary": "Vidyard is a video messaging and hosting platform built for sales and marketing teams, with screen and camera recording, viewer tracking and CRM integrations.",
    "differentiator": "Vidyard is built around sales video messaging, CRM integrations and viewer tracking; CaptureCat focuses on producing polished screen videos with automatic zoom, cursor effects and on-device captions, free and without a monthly video cap. CaptureCat Pro also has share links with viewer analytics, but no CRM integrations or team plan yet.",
    "pickThemWhen": "you send video messages to prospects and need view tracking tied into your CRM.",
    "strengths": [
      "Viewer analytics and notifications built for sales follow-up",
      "CRM and marketing automation integrations on Teams and Enterprise",
      "Records from a Chrome or Edge extension or desktop apps for Mac and Windows"
    ],
    "tradeoffs": [
      "Free plan allows 5 videos per month",
      "Starter costs $59 per seat per month billed annually",
      "Editor is minimal (trim and stitch); no zoom or cursor effects"
    ],
    "features": [
      false,
      false,
      "Cloud, paid plans",
      "Zapier MCP only; API on Enterprise",
      true,
      "Free, 5 videos/month",
      false,
      "Chrome/Edge extension, macOS & Windows",
      "Free · Starter $59/seat/mo (annual) or $89 monthly; Teams custom"
    ],
    "switchTip": "If your workflow depends on Vidyard's CRM integrations, keep it for prospect outreach and use CaptureCat for product demos and tutorials; export from CaptureCat as MP4 and upload wherever you host.",
    "faqExtra": {
      "question": "Does Vidyard work on Mac?",
      "answer": "Yes. Vidyard offers a desktop app for macOS and Windows, as well as Chrome and Edge browser extensions."
    },
    "sources": [
      "https://knowledge.vidyard.com/hc/en-us/articles/360022762634",
      "https://www.tella.com/vidyard-alternative",
      "https://www.vidyard.com/pricing.md",
      "https://www.vidyard.com/pricing/",
      "https://zapier.com/mcp/vidyard",
      "https://knowledge.vidyard.com/hc/en-us/articles/1260802687890",
      "https://www.businesswire.com/news/home/20210317005275/en/Vidyard-Launches-Desktop-Apps-as-Adoption-of-User-Generated-Videos-in-Sales-Accelerates"
    ]
  },
  {
    "slug": "screenpal",
    "name": "ScreenPal",
    "website": "https://screenpal.com",
    "category": "async",
    "summary": "ScreenPal, formerly Screencast-O-Matic, is a screen recorder, video editor and video hosting service aimed at education and business, with quizzes and AI tools on higher tiers.",
    "differentiator": "CaptureCat's free tier has no recording time limit, records system audio, and includes automatic zoom from clicks, cursor smoothing with click ripples and on-device captions, none of which ScreenPal's free plan offers. ScreenPal covers more platforms natively, including Windows, Chromebook and mobile, and has quizzes, which CaptureCat does not.",
    "pickThemWhen": "you need one recorder across Mac, Windows and Chromebooks, plus hosted videos with quizzes for students or staff.",
    "strengths": [
      "Runs on Mac, Windows, Chromebook, iOS and Android",
      "Low entry price, with a free plan that has no watermark",
      "Built-in video hosting with quizzes, plus heatmap analytics on Max"
    ],
    "tradeoffs": [
      "Free plan caps recordings at 15 minutes and 10 hosted videos",
      "Free plan cannot record system audio",
      "Auto captions and viewer analytics sit on paid tiers"
    ],
    "features": [
      "Manual zoom only",
      "Cursor editing on paid plans",
      "Auto captions, paid plans",
      false,
      "Analytics on Max and Team plans",
      "Free, 15-min limit, 10 hosted videos",
      false,
      "Mac, Windows, Chromebook, iOS, Android",
      "Free · Deluxe $4/mo, Max $10/mo (annual); Team $8/user/mo"
    ],
    "switchTip": "Download your ScreenPal videos as MP4 before switching; CaptureCat can't import ScreenPal projects, so start new recordings in CaptureCat and keep old hosted links where they are.",
    "faqExtra": {
      "question": "Is ScreenPal the same as Screencast-O-Matic?",
      "answer": "Yes. Screencast-O-Matic renamed itself ScreenPal, and existing Screencast-O-Matic logins and content carried over to ScreenPal."
    },
    "sources": [
      "https://screenpal.com/plans",
      "https://screenpal.com/video-editor",
      "https://screenpal.com/blog/recorder-drawing-tools",
      "https://screenpal.com/tutorial/cursor-highlighting",
      "https://screenpal.com/screen-recorder",
      "https://www.learningrevolution.net/screenpal-review/",
      "https://www.guidde.com/knowledge-hub/screenpal-pricing-2026-complete-breakdown",
      "https://screenpal.com/blog/screenpal-announcement"
    ]
  },
  {
    "slug": "screencastify",
    "name": "Screencastify",
    "website": "https://www.screencastify.com",
    "category": "async",
    "summary": "Screencastify is a browser-extension screen recorder, widely used in schools, now part of the Castify suite alongside AI video-to-document, editing and video-request tools.",
    "differentiator": "CaptureCat's free tier has unlimited recordings with no watermark, automatic zoom, cursor smoothing and on-device captions, while Screencastify gates captions to Pro and watermarks free videos. Screencastify's classroom integrations and quizzes have no CaptureCat equivalent; both offer a browser option on Chromebooks.",
    "pickThemWhen": "you teach or train on Chromebooks and want recordings that plug into Google Classroom or an LMS.",
    "strengths": [
      "Works anywhere Chrome or Edge runs, including Chromebooks",
      "Education features: interactive questions and Google Classroom, Canvas and Schoology integrations",
      "Viewer analytics show who watched and whether they finished"
    ],
    "tradeoffs": [
      "Free plan allows 10 videos of up to 30 minutes, with a watermark",
      "Captions, transcripts and AI tools require the Pro plan",
      "No native desktop app; recording runs through the browser extension"
    ],
    "features": [
      "Manual zoom only",
      "Click highlights at record time",
      "Cloud, Pro plan",
      false,
      "Full analytics on paid plans",
      "Free, 10 videos, 30-min limit, watermark",
      false,
      "Browser (Chrome/Edge extension)",
      "Free · Starter $7/user/mo (annual) or $19 monthly; Pro $10 or $25"
    ],
    "switchTip": "Download Screencastify videos you want to keep before your plan changes; teachers on Chromebooks can use CaptureCat's browser app in Chrome, while Mac users get the native app.",
    "faqExtra": {
      "question": "Is Screencastify now called Castify?",
      "answer": "The company rebranded as Castify in March 2026. Screencastify remains the name of the recording tool inside the Castify suite, alongside Castify Transform, Castify Edit and Castify Submit."
    },
    "sources": [
      "https://learn.screencastify.com/hc/en-us/sections/360008756634-How-to-Use-Edit",
      "https://www.screencastify.com/blog/how-to-use-record-toolbar",
      "https://www.screencastify.com/pricing",
      "https://www.castify.com/pricing",
      "https://learn.screencastify.com/hc/en-us/articles/4405788855575",
      "https://www.screencastify.com/blog/better-video-insights-and-flexible-settings",
      "https://www.screencastify.com/",
      "https://techintelpro.com/news/marketing/communications/screencastify-rebrands-to-castify-with-ai-transform-launch",
      "https://www.wboc.com/online_features/press_releases/screencastify-evolves-into-castify-high-impact-video-content-that-sticks-for-your-organization/article_daa9e7d4-a379-559f-b2cc-a501309d3dee.html"
    ]
  },
  {
    "slug": "jumpshare",
    "name": "Jumpshare",
    "website": "https://jumpshare.com",
    "category": "async",
    "summary": "Jumpshare is a screen recording, screenshot and file sharing tool that turns captures into share links with viewer analytics and AI summaries.",
    "differentiator": "CaptureCat's free tier has unlimited recording length, automatic zoom, cursor smoothing with click ripples and on-device captions; Jumpshare puts captions and analytics behind Plus. Jumpshare's Business plan matches CaptureCat Pro on AI titles and chapters, and Jumpshare also handles general file sharing, which CaptureCat does not.",
    "pickThemWhen": "you want one tool for quick recordings, screenshots and file sharing with link-level analytics.",
    "strengths": [
      "Combines screen recording, screenshots, GIFs and file sharing in one app",
      "Business plan adds AI titles, summaries and chapters",
      "Records up to 4K on paid plans, with transcription in 50+ languages"
    ],
    "tradeoffs": [
      "Free plan limits recordings to 5 minutes and 25 uploads",
      "Captions, transcripts and viewer analytics require a paid plan",
      "Click tracking is noted for Mac recordings only"
    ],
    "features": [
      null,
      "Click tracking at record time (Mac)",
      "Cloud, paid plans",
      false,
      "Analytics on paid plans",
      "Free, 5-min limit, 25 uploads",
      false,
      "macOS, Windows, browser, iPhone",
      "Free · Plus $12/mo, Business $16/user/mo (annual); $15/$20 monthly"
    ],
    "switchTip": "Download recordings you want to keep from Jumpshare as MP4; record new demos in CaptureCat and use Pro share links if you still need viewer analytics.",
    "sources": [
      "https://jumpshare.com/pricing",
      "https://Jmp.sh/screen-recorder-mac",
      "https://jumpshare.com/screen-recorder",
      "https://apps.apple.com/us/app/jumpshare-screen-recorder/id889922906",
      "https://trupeer.ai/tools-comparison/jumpshare-vs-trupeer-pricing"
    ]
  },
  {
    "slug": "guidde",
    "name": "Guidde",
    "website": "https://www.guidde.com",
    "category": "async",
    "summary": "Guidde is an AI tool that captures a workflow in the browser and turns it into a step-by-step how-to video and guide with AI voiceover.",
    "differentiator": "Guidde builds step-based how-to guides with AI narration; CaptureCat records continuous screen video with automatic zoom from clicks, cursor smoothing and on-device captions, free and without a watermark. Guidde also has automatic pan and zoom on clicks in some modes, so both tools cover that, but CaptureCat applies it to any recording.",
    "pickThemWhen": "you need to turn software workflows into step-by-step training guides with AI voiceover at scale.",
    "strengths": [
      "Generates step-by-step videos and written guides from a single capture",
      "AI text-to-voice with 200+ voices and 50+ languages on paid tiers",
      "Exports to PDF and presentations and integrates with tools like Zendesk, Confluence and Salesforce"
    ],
    "tradeoffs": [
      "Free plan is limited to 25 videos and carries a Guidde watermark",
      "Desktop app capture and analytics require the Business plan",
      "Output is step-based how-to content rather than continuous screen video"
    ],
    "features": [
      "Auto pan & zoom on clicks (some modes)",
      "Auto click hotspots (interactive demos)",
      "Cloud, paid plans",
      false,
      "Analytics on Business plan",
      "Free, up to 25 videos, watermark",
      false,
      "Chrome/Edge ext.; desktop app (Business)",
      "Free · Pro $19/creator/mo (annual) or $29; Business $39 or $59"
    ],
    "switchTip": "Keep Guidde for documentation-style SOPs if your team relies on its written guides; use CaptureCat for narrated product demos and tutorials you export as MP4 or share via Pro links.",
    "sources": [
      "https://help.guidde.com/en/articles/8173774-add-motion-to-your-guidde-video-steps-pan-zoom-and-step-transitions",
      "https://help.guidde.com/en/articles/16801254-create-interactive-demos-in-guidde",
      "https://www.guidde.com/pricing"
    ]
  },
  {
    "slug": "mmhmm",
    "name": "Airtime (formerly mmhmm)",
    "website": "https://www.airtime.com",
    "category": "async",
    "summary": "Airtime (formerly mmhmm) is a set of video tools for work, including a screen recorder, a presentation recorder (Creator) and a virtual camera for meetings.",
    "differentiator": "CaptureCat's editor adds automatic zoom from clicks, cursor smoothing, click ripples and on-device captions, free with 4K export. Airtime's strengths are presenter effects and a virtual camera for live calls, which CaptureCat does not offer.",
    "pickThemWhen": "you present on camera over slides or screens and want a virtual camera for live meetings too.",
    "strengths": [
      "Presenter overlays that can be moved and resized after publishing",
      "Viewers can zoom into the shared screen on playback",
      "One subscription covers recorder, presentation studio and virtual camera"
    ],
    "tradeoffs": [
      "Recorder editing is limited to trimming start and end",
      "During the trial, Recorder is capped at 5 recordings of up to 5 minutes",
      "Viewer analytics for shared recordings are not documented"
    ],
    "features": [
      false,
      false,
      "Cloud transcript (Creator)",
      false,
      null,
      "14-day trial; Recorder 5 x 5-min clips",
      false,
      "macOS, Windows & browser",
      "$10/mo yearly or $12 monthly (per seat for teams)"
    ],
    "switchTip": "Download recordings as MP4 from Airtime before cancelling. Keep Airtime Camera if you use it for live calls.",
    "faqExtra": {
      "question": "What happened to mmhmm?",
      "answer": "mmhmm was renamed Airtime in April 2025 and split into separate tools: Camera, Recorder, Creator (the successor to the mmhmm app) and Stacks."
    },
    "sources": [
      "https://www.airtime.com/pricing",
      "https://www.airtime.com/recorder",
      "https://www.airtime.com/screen-recorder",
      "https://www.airtime.com/recordings",
      "https://techcrunch.com/2025/04/24/evernote-founders-video-startup-mmhmm-becomes-airtime-launches-new-products",
      "https://www.airtime.com/blog/mmhmm-becomes-airtime"
    ]
  },
  {
    "slug": "berrycast",
    "name": "Berrycast",
    "website": "https://www.berrycast.com",
    "category": "async",
    "summary": "Berrycast is a screen and webcam video messaging tool for Windows and Mac, with share links, timed comments and a HIPAA-compliant option.",
    "differentiator": "CaptureCat's recorder and editor are free, with automatic zoom from clicks, cursor smoothing and on-device captions; Pro adds share links with viewer analytics. Berrycast offers HIPAA compliance and a native Windows app, which CaptureCat does not.",
    "pickThemWhen": "you need a simple Loom-style recorder for Windows and Mac, especially one that can be HIPAA compliant.",
    "strengths": [
      "Unlimited videos and recording length on every paid plan",
      "HIPAA-compliant option with a signed BAA for healthcare teams",
      "Viewers can leave video or timed comments without an account"
    ],
    "tradeoffs": [
      "No free plan, only a 14-day trial, and no refunds",
      "Transcripts are capped at 2 hours/month on Professional",
      "Section-level video analytics require the Enterprise plan"
    ],
    "features": [
      false,
      false,
      "Cloud subtitles, Professional+",
      false,
      "Views; full analytics on Enterprise",
      "Trial only (14 days)",
      false,
      "macOS & Windows",
      "$16-$29/user/mo, billed annually"
    ],
    "switchTip": "Download your Berrycast videos before your subscription ends. Stay on Berrycast if you need a BAA for patient data.",
    "sources": [
      "https://www.berrycast.com/pricing",
      "https://www.berrycast.com/"
    ]
  },
  {
    "slug": "bubbles",
    "name": "Bubbles",
    "website": "https://www.usebubbles.com",
    "category": "async",
    "summary": "Bubbles is a browser-based screen recorder and AI meeting notetaker for sending short async videos and meeting recordings to teammates.",
    "differentiator": "CaptureCat focuses on producing polished videos: a native Mac app plus a browser app, automatic zoom from clicks, cursor smoothing and on-device captions, all free and without watermark. Bubbles' MCP reads existing bubbles, while CaptureCat's MCP server lets agents record, edit and export.",
    "pickThemWhen": "you want quick browser recordings with threaded comments and an AI notetaker for your team's meetings.",
    "strengths": [
      "Free plan allows unlimited screen recordings up to 30 minutes each",
      "Combines async screen videos with a meeting notetaker for Zoom, Meet and Teams",
      "Official MCP server lets Claude read bubbles, transcripts and comments"
    ],
    "tradeoffs": [
      "Free recordings lock after two weeks; full AI transcripts need Pro",
      "Recording runs in the browser; the help center lists no native desktop app",
      "MCP is read-only apart from sending the notetaker to a meeting; it cannot record or edit screen videos"
    ],
    "features": [
      false,
      false,
      "Cloud transcripts, Pro plan",
      "Official MCP, mostly read-only",
      null,
      "Free, 30-min videos, lock after 2 weeks",
      false,
      "Browser (Chrome/Edge extension, web app)",
      "Free · Pro $12/member/mo yearly for 3+ members ($15 monthly); $18 ($22) for 1-2"
    ],
    "switchTip": "Download recordings you want to keep before free bubbles lock, then record new ones in CaptureCat; share links with comments and viewer analytics need CaptureCat Pro. CaptureCat has no meeting notetaker, so keep Bubbles if you rely on that.",
    "sources": [
      "https://www.usebubbles.com/pricing",
      "https://docs.usebubbles.com/mcp/",
      "https://docs.usebubbles.com/claude-app/",
      "https://help.usebubbles.com/en/articles/12699575-what-is-bubbles-screen-recording",
      "https://www.usebubbles.com/"
    ]
  },
  {
    "slug": "claap",
    "name": "Claap",
    "website": "https://www.claap.io",
    "category": "async",
    "summary": "Claap is an AI meeting and screen recorder from lemlist, now aimed mainly at sales and revenue teams, that records calls and screen videos and syncs notes to the CRM.",
    "differentiator": "CaptureCat is a screen-video recorder and editor first: automatic zoom from clicks, cursor smoothing with click ripples, on-device captions and 4K export are free with no watermark. Claap's MCP works on meeting and CRM data, while CaptureCat's built-in MCP server lets agents record, edit, render frames and export video.",
    "pickThemWhen": "your team mainly needs recorded sales calls, AI notes and CRM sync, with occasional screen videos on the side.",
    "strengths": [
      "Records meetings without a bot, plus screen and camera videos, in one workspace",
      "Official MCP server with 58 tools over recordings, transcripts, contacts and deals",
      "Transcripts in 99+ languages with AI summaries, chapters and CRM auto-fill on higher plans"
    ],
    "tradeoffs": [
      "Product focus has moved to sales call intelligence, not general async video",
      "Desktop app, AI subtitles and downloads require the paid Pro plan",
      "Mac desktop build is listed for Apple Silicon only"
    ],
    "features": [
      false,
      false,
      "Cloud; subtitles on Pro plan+",
      "Official MCP, meeting/CRM data only",
      true,
      "Free, 10 videos/user, 300 min total",
      false,
      "Chrome extension; Mac (Apple Silicon) & Windows apps",
      "Free · Pro €24/license/mo yearly (€30 monthly) · Business €48 (€60)"
    ],
    "switchTip": "Download any Claap videos you want to keep (a Pro feature) before cancelling. Keep Claap if you rely on its meeting bot or CRM sync; CaptureCat does not record meetings or sync to a CRM.",
    "faqExtra": {
      "question": "Is Claap still a Loom-style screen recorder?",
      "answer": "It still records screen and camera through a Chrome extension and a desktop app, but after lemlist acquired it in 2025 the product and pricing are aimed at sales teams, with meeting recording, AI coaching and CRM auto-complete."
    },
    "sources": [
      "https://www.claap.io/pricing",
      "https://help.claap.io/en/articles/11786373-using-claap-s-mcp-server",
      "https://help.claap.io/en/articles/16440882-downloading-and-installing-the-claap-desktop-app",
      "https://finder.techleap.nl/news/feed/lemlist-acquires-claap-for-eight-figures",
      "https://nordic9.com/news/claap-was-acquired-by-lemlist-in-france/",
      "https://www.claap.io/"
    ]
  },
  {
    "slug": "hippo-video",
    "name": "Hippo Video",
    "website": "https://www.hippovideo.io",
    "category": "async",
    "summary": "Hippo Video is a video messaging and personalization platform for sales teams, with screen and camera recording, sales pages and CRM integrations.",
    "differentiator": "CaptureCat is aimed at polished screen videos rather than sales outreach: automatic zoom from clicks, cursor smoothing, on-device captions and 4K export are free. It has no CRM integrations or personalization features.",
    "pickThemWhen": "you send personalized sales videos at volume and need CRM tracking of who watched.",
    "strengths": [
      "Built for sales outreach: personalized videos, sales pages and interactive CTAs",
      "Deep CRM and sales-tool integrations (HubSpot, Outreach, Salesloft, Salesforce)",
      "Per-viewer reports such as play rate and watch duration"
    ],
    "tradeoffs": [
      "Closed captions are metered (10 min/mo free, 30 on Pro)",
      "Editing is basic compared with a dedicated screen-video editor",
      "Pricing climbs quickly for team features ($60 to $80 per user)"
    ],
    "features": [
      false,
      false,
      "Cloud captions, minutes per plan",
      "No MCP; has Video API/SDK",
      true,
      "Free, 30-min recordings, 50 videos/mo",
      false,
      "Chrome extension, Mac & Windows apps, iOS & Android",
      "Free · Pro $20/user/mo yearly ($30 monthly) · Teams $60 ($75)"
    ],
    "switchTip": "Keep Hippo Video for sales sequences that depend on its CRM tracking; use CaptureCat for product demos and tutorials and share the exported files or a CaptureCat Pro link.",
    "sources": [
      "https://www.hippovideo.io/pricing.html"
    ]
  },
  {
    "slug": "komodo",
    "name": "Kommodo",
    "website": "https://kommodo.ai",
    "category": "async",
    "summary": "Kommodo (formerly Komodo, komododecks.com) is a screen recorder with a cloud video editor, AI transcripts and auto-generated step-by-step guides.",
    "differentiator": "CaptureCat records and edits locally with automatic zoom from clicks, cursor smoothing, click ripples and on-device captions, free with unlimited recordings. Kommodo's API and skill manage recording metadata and pages, while CaptureCat's MCP server lets agents record, edit and export the video itself.",
    "pickThemWhen": "you want recordings that also become written how-to guides and shareable pages for a team.",
    "strengths": [
      "Free plan has no watermark and no recording time limit (15 videos)",
      "Turns recordings into step-by-step SOP guides and landing pages",
      "Transcript-based editing and a public REST API with an open-source agent skill"
    ],
    "tradeoffs": [
      "Free plan is capped at 15 videos; unlimited needs Premium",
      "Editing and rendering happen in the cloud, not on your machine",
      "No automatic zoom or cursor effects are listed in its editor"
    ],
    "features": [
      false,
      false,
      "Cloud auto-captions",
      "No MCP; REST API + agent skill",
      true,
      "Free, 15 videos, no watermark",
      false,
      "macOS, Windows, Chrome extension, iOS, Android",
      "Free · Premium $9/user/mo yearly or $15 monthly"
    ],
    "switchTip": "Download your Kommodo videos (downloads are a Premium feature per its plan table) before switching. Kommodo's SOP guides and page builder have no CaptureCat equivalent, so keep it if you use those.",
    "faqExtra": {
      "question": "Is Kommodo the same as Komodo?",
      "answer": "Yes. komododecks.com now redirects to kommodo.ai, and the site states Kommodo is a registered trademark of Komodo Technologies."
    },
    "sources": [
      "https://kommodo.ai/pricing",
      "https://kommodo.ai/developer",
      "https://kommodo.ai/products/video-editor"
    ]
  },
  {
    "slug": "supercut",
    "name": "Supercut",
    "website": "https://supercut.ai",
    "category": "async",
    "summary": "Supercut is a Loom-style async video platform with native Mac and Windows recorders, an editor, AI summaries and hosted sharing for teams.",
    "differentiator": "Both have native recorders and an MCP, but Supercut's MCP reads existing recordings while CaptureCat's lets agents record, edit, render frames and export. CaptureCat also adds automatic zoom from clicks and cursor smoothing, and its editor and on-device captions are free; Supercut covers Windows natively, which CaptureCat does only through its browser app.",
    "pickThemWhen": "your team wants a polished Loom replacement with native recorders, AI summaries and an MCP that feeds recordings to coding agents.",
    "strengths": [
      "Native macOS and Windows recorders with up to 4K and multi-stream capture",
      "Auto-Edit removes filler words and silences; captions in 110 languages",
      "Official MCP gives agents transcripts, frames, comments and reactions"
    ],
    "tradeoffs": [
      "No free plan: after the 14-day trial, sharing, downloading and uploading pause",
      "Zooms are placed by hand in the editor",
      "Videos are capped at 1 hour each on Pro"
    ],
    "features": [
      "Manual zoom only",
      false,
      "Cloud auto-captions",
      "Official MCP, read access to videos",
      true,
      "14-day trial; sharing pauses after",
      false,
      "macOS & Windows",
      "£12/seat/mo yearly or £14 monthly (GBP shown)"
    ],
    "switchTip": "Download the videos you want to keep while your Supercut subscription is active. CaptureCat Pro covers share links with comments and viewer analytics, but it has no team plan yet.",
    "sources": [
      "https://supercut.ai/pricing",
      "https://help.supercut.ai/en/articles/14341426-zoom",
      "https://supercut.ai/polish",
      "https://supercut.ai/llms.txt",
      "https://supercut.ai/agents"
    ]
  },
  {
    "slug": "vimeo-record",
    "name": "Vimeo Record",
    "website": "https://vimeo.com/features/screen-recorder",
    "category": "async",
    "summary": "Vimeo Record is Vimeo's free screen and webcam recorder, running in the browser and a Chrome extension, that uploads straight into Vimeo's video hosting.",
    "differentiator": "CaptureCat records natively on Mac (and in the browser elsewhere) with automatic zoom from clicks, cursor smoothing and on-device captions, and exports 4K files free. Vimeo is stronger as a hosting platform; CaptureCat Pro covers share links with viewer analytics, not full video hosting.",
    "pickThemWhen": "you already host video on Vimeo and want quick recordings in the same library and player.",
    "strengths": [
      "Recordings land in an ad-free Vimeo player and hosting library",
      "Engagement analytics show who watched and for how long",
      "Teleprompter, AI script help and text-based editing included"
    ],
    "tradeoffs": [
      "Free plan caps each recording at 30 minutes",
      "No desktop recorder; recording happens in the browser",
      "Owned by Bending Spoons since late 2025, with major layoffs after, so plans may change"
    ],
    "features": [
      false,
      false,
      "Cloud auto-captions",
      "No official MCP (REST API only)",
      true,
      "Free plan, 30-min recordings",
      false,
      "Browser (Chrome, Edge, Safari) + Chrome extension",
      "Free · paid from £10.80/mo yearly (UK price shown)"
    ],
    "switchTip": "Keep your Vimeo account for hosting if you need it; you can export from CaptureCat and upload the MP4 to Vimeo.",
    "sources": [
      "https://vimeo.com/upgrade-plan",
      "https://vimeo.com/features/screen-recorder",
      "https://help.vimeo.com/hc/en-us/articles/23558705628049-Vimeo-Record-Chrome-extension",
      "https://glama.ai/mcp/servers/integrations/vimeo",
      "https://www.newsshooter.com/2025/09/10/vimeo-sold-to-italian-app-developer-bending-spoons-for-1-38-billion/",
      "https://www.storyboard18.com/brand-marketing/vimeo-layoffs-2026-bending-spoons-confirms-new-staff-cuts-after-1-38b-acquisition-88104.htm"
    ]
  },
  {
    "slug": "camtasia",
    "name": "Camtasia",
    "website": "https://www.techsmith.com/camtasia/",
    "category": "editor",
    "summary": "Camtasia is TechSmith's screen recorder and timeline video editor for tutorials and training videos, sold as an annual subscription for Mac and Windows.",
    "differentiator": "Camtasia matches CaptureCat on automatic zoom from cursor and click data, cursor effects and on-device captions, and it runs natively on Windows. CaptureCat's free tier exports without a watermark at up to 4K 60 fps, it is open source under AGPL-3.0, and it has a built-in MCP server for coding agents.",
    "pickThemWhen": "you produce longer training or course videos on Windows or Mac and want a full timeline editor with assets and AI voiceover.",
    "strengths": [
      "Full timeline editor with assets, animations and SmartFocus, which adds zoom-and-pan from recorded cursor and click data",
      "Cursor smoothing, click highlights and on-device caption transcription (Camtasia 2024 and later)",
      "Runs on both Windows and macOS, with AI voice, script and avatar tools on higher tiers"
    ],
    "tradeoffs": [
      "Annual subscription only; the $39/yr Starter plan exports with a watermark",
      "Clean exports start at Essentials ($179.88/yr); AI voice and avatars need Create or Pro",
      "A full video editor has more to learn than a recorder with automatic editing"
    ],
    "features": [
      true,
      true,
      "On-device, Essentials plan and up",
      false,
      "Screencast links, view counts",
      "Free trial, no time limit, watermark",
      false,
      "macOS & Windows",
      "$39/yr (watermarked) to $599/yr"
    ],
    "switchTip": "Record your next tutorial in CaptureCat and compare its automatic zoom and captions with SmartFocus before your Camtasia renewal date. Keep Camtasia for projects that depend on its asset library or AI voiceover.",
    "faqExtra": {
      "question": "Can I still buy Camtasia once?",
      "answer": "TechSmith moved to annual subscription pricing in 2025; current plans are Starter ($39/yr), Essentials ($179.88/yr), Create ($249/yr) and Pro ($599/yr)."
    },
    "sources": [
      "https://www.techsmith.com/camtasia/",
      "https://www.techsmith.com/learn/tutorials/camtasia/animations/",
      "https://www.techsmith.com/store/camtasia",
      "https://support.techsmith.com/hc/en-us/articles/26713588518413-Dynamic-Captions-Best-Practices",
      "https://techsmith.com/learn/tutorials/screencast/media-location",
      "https://www.techsmith.com/screencast/",
      "https://support.techsmith.com/hc/en-us/articles/26035447040525-Can-I-Try-For-Free-Before-Purchasing-a-Camtasia-Plan",
      "https://support.techsmith.com/hc/en-us/articles/40593880288397-Getting-Started-with-a-Camtasia-Starter-Plan",
      "https://www.techsmith.com/store/camtasia?bvstate=pg%3A42%2Fct%3Ar",
      "https://trainn.co/blog/camtasia-pricing/",
      "https://support.techsmith.com/hc/en-us/articles/27009223314701-TechSmith-Transition-to-Annual-Subscription-Pricing-Model-in-2025",
      "https://www.techsmith.com/camtasia/whats-new/"
    ]
  },
  {
    "slug": "screenflow",
    "name": "ScreenFlow",
    "website": "https://www.telestream.net/screenflow/overview.htm",
    "category": "editor",
    "summary": "ScreenFlow by Telestream is a Mac-only screen recorder and multi-track video editor sold as a one-time purchase.",
    "differentiator": "ScreenFlow is a deeper general-purpose editor; CaptureCat focuses on screen recordings, adding zoom automatically from recorded clicks, generating on-device captions, and offering share links with analytics on Pro. CaptureCat's core app is free and open source (AGPL-3.0) and has a built-in MCP server for coding agents.",
    "pickThemWhen": "you want a mature, timeline-based Mac video editor you pay for once and are happy to place zooms and callouts by hand.",
    "strengths": [
      "Full multi-track editor with transitions, text and video animations, nested clips and markers.",
      "One-time purchase rather than a subscription.",
      "Native system audio recording without a driver since 10.5, plus iPhone/iPad screen recording and an optional stock media library."
    ],
    "tradeoffs": [
      "No automatic zoom; zooms and cursor callouts are added by hand on the timeline.",
      "No built-in speech-to-text; the caption editor is for adding or importing captions.",
      "Mac only, and the stock media library is a separate $99/yr subscription after the first year."
    ],
    "features": [
      "Manual zoom & cursor callouts",
      "Click effects, pointer styling in post",
      "Manual caption editor only",
      false,
      false,
      "Unlimited trial, watermarked exports",
      false,
      "macOS",
      "$199 one-time; Super Pak from $275"
    ],
    "switchTip": "ScreenFlow projects (.screenflow) don't open in CaptureCat, so finish open projects in ScreenFlow and start new recordings in CaptureCat. Both run natively on Apple silicon and Intel Macs.",
    "faqExtra": {
      "question": "Can ScreenFlow record system audio without extra software?",
      "answer": "Yes. ScreenFlow 10.5 (August 2025) added native system audio recording without installing a driver, plus options to exclude apps or record app audio separately. ScreenFlow 10.5 supports macOS Sequoia and Tahoe."
    },
    "sources": [
      "https://www.telestream.net/screenflow/overview.htm",
      "https://www.telestream.net/screenflow/versions.htm",
      "https://www.telestream.net/telestream-support/screen-flow/help/Editing.06.22.html",
      "https://www.telestream.net/pdfs/user-guides/ScreenFlow-6-Tutorial.pdf",
      "https://support.telestream.net/s/article/Screen-Recording-Properties",
      "https://support.telestream.net/s/article/ScreenFlow-5-Editing-ScreenFlow-Projects-Creating-Closed-Captions",
      "https://www.telestream.net/screenflow/store.asp",
      "https://www.telestream.net/telestream-cloud/timed-text-speech.htm"
    ]
  },
  {
    "slug": "descript",
    "name": "Descript",
    "website": "https://www.descript.com",
    "category": "editor",
    "summary": "Descript is a text-based audio and video editor with a built-in screen recorder, cloud transcription and an AI co-editor called Underlord.",
    "differentiator": "Descript and CaptureCat both offer an official MCP server, but CaptureCat's can also start recordings and render frames, and it runs locally. CaptureCat adds zoom automatically from recorded clicks, runs captions on-device, has no media-hour caps or watermark on its free tier, and its Pro share links track watch time and retention.",
    "pickThemWhen": "you edit talking-head, podcast or narrated videos and want to cut by editing the transcript.",
    "strengths": [
      "Edit video by editing its transcript, with filler-word and retake removal.",
      "Underlord AI co-editor plus an official API and MCP server for Claude, ChatGPT and Cursor.",
      "Transcription in 25 languages and animated captions on every plan."
    ],
    "tradeoffs": [
      "Plans cap media hours (60 minutes a month on Free) and the Free plan exports 720p with a watermark.",
      "Zoom and pan are manual keyframes; there is no automatic zoom from clicks.",
      "Share pages show a total view count but no watch-time analytics."
    ],
    "features": [
      "Manual zoom only",
      "Click highlights at record time",
      "Cloud auto-captions",
      "Official MCP for import & editing",
      "Share pages, view count only",
      "Free, 60 media min/mo, 720p watermark",
      false,
      "macOS, Windows & browser",
      "Free · paid $16-$50/person/mo (annual)"
    ],
    "switchTip": "Export finished Descript videos as MP4 before switching, since Descript projects don't open elsewhere. If you rely on transcript-based editing or Rooms remote recording, keep Descript for that work and use CaptureCat for screen demos.",
    "faqExtra": {
      "question": "Does Descript have an MCP server?",
      "answer": "Yes. Descript offers a first-party MCP server that lets Claude, ChatGPT, Cursor or other MCP clients import media, edit projects with Underlord, export transcripts and publish. API access is included for paying users and draws on the plan's AI credits and media minutes."
    },
    "sources": [
      "https://www.descript.com/pricing",
      "https://www.descript.com/screen-recorder",
      "https://www.descript.com/blog/article/how-to-zoom-in-on-a-video-using-descript",
      "https://www.descript.com/blog/article/how-to-record-video-on-mac",
      "https://help.descript.com/api-and-mcp/mcp",
      "https://www.descript.com/api",
      "https://help.descript.com/export-and-share/share-page-settings",
      "https://help.descript.com/hc/en-us/articles/10503411779213-Descript-system-requirements",
      "https://www.descript.com/blog/article/descript-season-7-rooms-zoom-automatic-multicam"
    ]
  },
  {
    "slug": "democreator",
    "name": "Wondershare DemoCreator",
    "website": "https://democreator.wondershare.com",
    "category": "editor",
    "summary": "Wondershare DemoCreator is a screen recorder and video editor for Windows and macOS, with an online recorder and a set of AI tools paid for with credits.",
    "differentiator": "Both offer automatic zoom and cursor effects. CaptureCat includes them in its free version along with on-device English captions and 4K 60 fps export with no watermark or length cap, plus an MCP server for AI agents and AGPL-3.0 source. CaptureCat has no native Windows app: on Windows it runs as a browser app, where click-based auto zoom and cursor smoothing are not available (they need a Mac recording).",
    "pickThemWhen": "you want a native Windows or Mac recorder with automatic zoom, a full timeline editor and a large template library, and AI credits fit your budget.",
    "strengths": [
      "Smart Zoom adds pan and zoom animations automatically after recording",
      "Cursor highlight, magnify and click effects, plus real-time screen drawing",
      "Separate screen, camera and mic tracks, a teleprompter, and a perpetual licence option"
    ],
    "tradeoffs": [
      "The free trial caps exports at 5 minutes, 1080p 30 fps, with a watermark",
      "Auto subtitles and other AI tools consume AI credits",
      "The larger creative-asset library is a separate add-on subscription"
    ],
    "features": [
      "Smart Zoom, added after recording",
      "Highlight, magnify, click effects",
      "Yes, uses AI credits (paid plans)",
      false,
      "Share links, no analytics listed",
      "Trial: 5-min exports, watermark",
      false,
      "Windows, macOS & browser",
      "$9.99/mo, $59.99/yr or $79.99 once (often discounted)"
    ],
    "switchTip": "DemoCreator projects don't move over, so finish open edits there and export them. On Mac, start new recordings in CaptureCat and compare the automatic zoom side by side; Windows users get the CaptureCat browser app without auto zoom.",
    "sources": [
      "https://democreator.wondershare.com/whats-new.html",
      "https://democreator.wondershare.com/",
      "https://democreator.wondershare.com/store/windows-individuals.html"
    ]
  },
  {
    "slug": "movavi-screen-recorder",
    "name": "Movavi Screen Recorder",
    "website": "https://www.movavi.com/screen-recorder/",
    "category": "editor",
    "summary": "Movavi Screen Recorder is a paid desktop screen recorder for Windows and macOS with webcam capture, on-screen drawing, scheduled recording and basic trimming.",
    "differentiator": "On Mac, CaptureCat's free version adds what Movavi's recorder lacks: automatic zoom from recorded clicks, cursor smoothing with click ripples and on-device English captions, with no trial period or watermark. CaptureCat has no native Windows app: on Windows it runs as a browser app, where click-based auto zoom and cursor smoothing are not available (they need a Mac recording). Movavi has a native Windows app.",
    "pickThemWhen": "you want a simple, inexpensive recorder on Windows or Mac that shows clicks and keystrokes, and you do your heavier editing elsewhere.",
    "strengths": [
      "Highlights the mouse cursor, clicks and keystrokes while recording",
      "Records system audio and microphone, with scheduled recording and AI noise reduction",
      "Actively maintained on both Windows and macOS, with a low-cost monthly option"
    ],
    "tradeoffs": [
      "The trial lasts 7 days and watermarks output videos",
      "No automatic zoom; auto subtitles live in the separate Movavi Video Editor",
      "Subscription licence, and no hosted share pages of its own"
    ],
    "features": [
      false,
      "Cursor, click, keystroke highlights",
      "No; in Movavi Video Editor (separate)",
      false,
      false,
      "7-day trial, watermark",
      false,
      "Windows & macOS",
      "$19.95/mo or $64.95/yr (often discounted)"
    ],
    "switchTip": "Movavi saves standard video files, so existing recordings stay usable. On Mac, record your next tutorial in CaptureCat to get auto zoom and captions without a second editor; on Windows, try the CaptureCat browser app first, knowing auto zoom and cursor smoothing are Mac-only.",
    "faqExtra": {
      "question": "Is Movavi Screen Recorder free?",
      "answer": "No. Movavi offers a 7-day trial that adds a watermark to output videos; after that it is a paid subscription, from $19.95 per month or $64.95 per year at list price."
    },
    "sources": [
      "https://www.movavi.com/screen-recorder/",
      "https://www.movavi.com/adv/how-to-add-auto-subtitles.html",
      "https://www.movavi.com/screen-recorder-mac/",
      "https://www.movavi.com/screen-recorder/buynow.html"
    ]
  },
  {
    "slug": "clipchamp",
    "name": "Microsoft Clipchamp",
    "website": "https://clipchamp.com",
    "category": "editor",
    "summary": "Microsoft Clipchamp is a browser-based video editor with a Windows app, a built-in screen and camera recorder, and free cloud auto-captions.",
    "differentiator": "Both are free with no watermark. CaptureCat's Mac app adds automatic zoom from recorded clicks, cursor smoothing with click ripples, captions transcribed on-device rather than in the cloud, free 4K 60 fps export, and an MCP server for AI agents. CaptureCat has no native Windows app: on Windows it runs as a browser app, where click-based auto zoom and cursor smoothing are not available (they need a Mac recording).",
    "pickThemWhen": "you are on Windows or already pay for Microsoft 365 and want a free, general-purpose editor with captions and a basic recorder.",
    "strengths": [
      "Free plan exports up to 1080p with no watermark",
      "Autocaptions are free for all users and support many languages",
      "Built into Windows 11, and Premium is included with Microsoft 365 Personal and Family"
    ],
    "tradeoffs": [
      "Screen and webcam recordings are limited to 30 minutes each",
      "No native Mac app; on Mac it runs only in Chrome or Edge",
      "Captions are processed in the cloud by Azure, and 4K export needs Premium"
    ],
    "features": [
      "Manual zoom effects only",
      null,
      "Cloud auto-captions, free plan too",
      false,
      "Work accounts only, via SharePoint",
      "Free, 1080p export, no watermark",
      false,
      "Browser (Chrome/Edge), Windows, iOS",
      "Free · Premium via Microsoft 365 Personal/Family"
    ],
    "switchTip": "Export finished Clipchamp edits before switching, since projects don't transfer. Mac users get the most from CaptureCat's native app; on Windows, the CaptureCat browser app is closer to Clipchamp in features because auto zoom and cursor smoothing need a Mac recording.",
    "faqExtra": {
      "question": "Does Clipchamp work on Mac?",
      "answer": "Only in a browser. Microsoft says there is no Mac app; on a Mac you use the latest desktop version of Microsoft Edge or Google Chrome. Safari and Firefox are not supported."
    },
    "sources": [
      "https://clipchamp.com/en/blog/video-effects-to-enhance-video-editing/",
      "https://clipchamp.com/screen-recorder/",
      "https://support.microsoft.com/en-us/clipchamp/how-to-use-autocaptions-in-clipchamp",
      "https://clipchamp.com/en/pricing/",
      "https://learn.microsoft.com/en-us/clipchamp/features-clipchamp",
      "https://support.microsoft.com/en-US/Clipchamp/which-devices-does-clipchamp-work-on",
      "https://support.microsoft.com/en-US/Clipchamp/which-web-browsers-does-clipchamp-support"
    ]
  },
  {
    "slug": "veed",
    "name": "VEED",
    "website": "https://www.veed.io",
    "category": "editor",
    "summary": "VEED is a browser-based video editor with a screen and webcam recorder, auto subtitles, AI generation tools and video hosting.",
    "differentiator": "CaptureCat's Mac app adds automatic zoom from recorded clicks, cursor smoothing and on-device captions to its free version, with no watermark and export up to 4K 60 fps. CaptureCat's MCP server records, edits and exports, while VEED's MCP generates new videos from prompts or images. CaptureCat has no native Windows app: on Windows it runs as a browser app, where click-based auto zoom and cursor smoothing are not available (they need a Mac recording).",
    "pickThemWhen": "you want an online editor for social and marketing video with subtitles, translation and AI generation, and screen recording is only part of the job.",
    "strengths": [
      "Runs in the browser with nothing to install, plus an iOS app",
      "Auto subtitles, subtitle translation and AI dubbing",
      "Hosted share links with comments and privacy controls, and a broad AI toolset"
    ],
    "tradeoffs": [
      "Free plan exports at 720p with a watermark and a 10-minute limit",
      "Zoom in the web editor is placed manually, one zoom per clip",
      "Per-seat billing, and many AI features draw on credits"
    ],
    "features": [
      "Manual in web; AI zooms in iOS app",
      null,
      "Cloud; 10 min/mo free, paid unlimited",
      "Official MCP, video generation only",
      "Share links; analytics unverified",
      "Free: 720p, watermark, 10-min export",
      false,
      "Browser (+ iOS app)",
      "Free · Creator $25/mo or $147/yr per user"
    ],
    "switchTip": "Download your finished VEED exports first, since projects don't transfer. Use CaptureCat for screen tutorials and demos, and keep VEED if you rely on its translation, dubbing or AI generation.",
    "sources": [
      "https://support.veed.io/en/articles/11647313-how-to-add-zoom-to-your-videos",
      "https://mobile-support.veed.io/en/articles/12630383-how-to-automatically-add-zooms-in-the-ios-app",
      "https://www.veed.io/pricing",
      "https://www.veed.io/tools/veed-mcp",
      "https://support.veed.io/en/articles/11029688-share-your-videos",
      "https://www.veed.io/tools/screen-recorder",
      "https://magichour.ai/blog/veed-pricing"
    ]
  },
  {
    "slug": "activepresenter",
    "name": "ActivePresenter",
    "website": "https://atomisystems.com/activepresenter/",
    "category": "editor",
    "summary": "ActivePresenter by Atomi Systems is an eLearning authoring tool for Windows and macOS that combines screen recording, video editing, and interactive SCORM/xAPI course export.",
    "differentiator": "CaptureCat's native Mac app zooms automatically from recorded clicks and transcribes on-device for free, but has no quizzes or SCORM export. CaptureCat has no native Windows app; on Windows it runs as a browser app (Chrome/Edge 113+, Firefox 141+), and click-based auto zoom and cursor smoothing are not available there.",
    "pickThemWhen": "you build software training or interactive courses and need SCORM/xAPI output, quizzes, and branching.",
    "strengths": [
      "Records mouse movement as editable cursor paths, with click sounds, click effects, and cursor highlights adjustable after recording.",
      "Exports interactive simulations and quizzes to HTML5, SCORM, and xAPI for LMSs.",
      "Perpetual licenses with one year of free major upgrades, and an unlimited-time free edition."
    ],
    "tradeoffs": [
      "Zoom-n-Pan is placed and sized by hand; there is no automatic zoom.",
      "AI tools, including speech-to-text captions, need a paid edition, AI credits, and an internet connection.",
      "The free edition is for trial and non-commercial use, and outputs using paid features carry a watermark."
    ],
    "features": [
      "Manual zoom only",
      "Editable cursor paths and click effects",
      "Cloud AI, paid editions + credits",
      false,
      "Via separate uPresenter service",
      "Free for non-commercial use, watermark",
      false,
      "Windows & macOS",
      "$249 Standard or $499 Pro, one-time"
    ],
    "switchTip": "Switch only the video-tutorial part of your workflow; keep ActivePresenter for interactive courses and LMS packages, since CaptureCat does not export SCORM or xAPI.",
    "faqExtra": {
      "question": "Is the free edition of ActivePresenter allowed for commercial use?",
      "answer": "No. Atomi Systems says the free edition is for trial and non-commercial use; outputs that use non-free features get a watermark until a license is activated."
    },
    "sources": [
      "https://atomisystems.com/activepresenter/",
      "https://atomisystems.com/download/",
      "https://atomisystems.com/pricing/",
      "https://atomisystems.com/tutorials/ap8/how-to-use-zoom-n-pan-in-activepresenter-8/",
      "https://atomisystems.com/tutorials/ap7/adding-cursor-paths/",
      "https://atomisystems.com/tutorials/activepresenter-10/speech-to-text-activepresenter-10/",
      "https://atomisystems.com/tutorials/activepresenter-10/how-do-ai-credits-work/"
    ]
  },
  {
    "slug": "canva",
    "name": "Canva",
    "website": "https://www.canva.com",
    "category": "editor",
    "summary": "Canva is an online design platform whose desktop app includes a free screen recorder that saves each recording as an editable Canva video design.",
    "differentiator": "Canva's recorder feeds a design tool; CaptureCat is a dedicated screen recorder with automatic zoom from recorded clicks, cursor smoothing and click ripples, on-device captions and 4K 60 fps export, free and without a watermark. Both have an official MCP server, but CaptureCat's can record, edit and export screen video.",
    "pickThemWhen": "your team already designs in Canva and wants quick recordings that live alongside slides, social posts and brand assets.",
    "strengths": [
      "Screen recorder is free, with screen, camera or both, up to 25 minutes per recording",
      "Recordings drop straight into Canva's editor with templates, brand kits and auto-captions in 50+ languages",
      "Official MCP server for creating, editing and exporting Canva designs from AI assistants"
    ],
    "tradeoffs": [
      "The screen recorder only works in the Canva desktop app, not in the browser or on mobile",
      "Recordings are capped at 25 minutes and 1 GB",
      "Built for design and presentation videos rather than polished software demos"
    ],
    "features": [
      null,
      null,
      "Auto-captions (location not stated)",
      "Official MCP (designs, not recording)",
      "View links; analytics on paid plans",
      "Free, 25-min recordings",
      false,
      "Canva desktop app (Mac & Windows)",
      "Free · Pro US$144/yr · Business US$250/yr per person"
    ],
    "switchTip": "Record and polish the walkthrough in CaptureCat, export MP4, and upload it to Canva if you want to place it inside a presentation or social design.",
    "faqExtra": {
      "question": "Can I use Canva's screen recorder in a web browser?",
      "answer": "No. Canva's help center says the Screen Recorder is only available in the Canva desktop app for Mac or Windows, not in the web browser or on mobile. Separately, the \"Record yourself\" option in the editor works in Chrome and Safari."
    },
    "sources": [
      "https://www.canva.com/pricing/",
      "https://www.canva.com/screen-recorder/",
      "https://www.canva.com/help/screen-recorder/",
      "https://www.canva.com/help/generate-edit-captions-on-videos/",
      "https://www.canva.com/features/auto-caption/",
      "https://canva.dev/docs/mcp/",
      "https://www.canva.com/help/view-design-insights/",
      "https://www.canva.com/help/recording-videos/"
    ]
  },
  {
    "slug": "capto",
    "name": "Capto",
    "website": "https://www.globaldelight.com/capto/",
    "category": "editor",
    "summary": "Capto by Global Delight is a screen capture, screen recording and basic video editing app for Mac (with a separate Windows version).",
    "differentiator": "Capto and CaptureCat both record screen, camera and iPhone/iPad and offer annotations. CaptureCat adds automatic zoom from clicks, cursor smoothing with ripples and on-device captions at no cost, while Capto is a one-time purchase after a 15-day trial.",
    "pickThemWhen": "you want a paid-once Mac app for screenshots and simple tutorial recordings with light editing.",
    "strengths": [
      "One-time purchase that covers screenshots, recording and editing",
      "Records Mac screen at 60 fps with system and mic audio on separate tracks, plus iPhone/iPad screens",
      "Cut, trim, crop, annotate and upload to YouTube, Dropbox or FTP from one app"
    ],
    "tradeoffs": [
      "No automatic zoom or AI captions",
      "Editing is basic compared with a full timeline editor",
      "Sharing goes to third-party services, not hosted links with analytics"
    ],
    "features": [
      false,
      "Click highlights while recording",
      false,
      false,
      false,
      "15-day trial",
      false,
      "macOS & Windows",
      "$29.99 one-time (2 Macs)"
    ],
    "switchTip": "Export any Capto recordings you still need as MP4, then record new tutorials in CaptureCat; its free tier needs no license to try the editor.",
    "faqExtra": {
      "question": "Is Capto a subscription?",
      "answer": "No. Global Delight sells Capto for Mac as a one-time purchase, listed at $29.99 on its site, after a 15-day trial."
    },
    "sources": [
      "https://www.globaldelight.com/capto/features",
      "https://www.globaldelight.com/store/",
      "https://www.hongkiat.com/blog/capto-screen-capture",
      "https://www.globaldelight.com/capto/",
      "https://www.globaldelight.com/capto/windows",
      "https://blog.globaldelight.com/capto-windows/master-screen-recording-and-editing-on-windows-with-capto",
      "https://apps.apple.com/us/app/capto-screen-capture-recorder/id1078184147?mt=12"
    ]
  },
  {
    "slug": "detail",
    "name": "Detail Studio",
    "website": "https://detail.co",
    "category": "editor",
    "summary": "Detail Studio for Mac is a desktop video production app for recording multiple cameras and the screen in one take, then editing and exporting; Detail also makes a separate iPhone/iPad app.",
    "differentiator": "Detail centres on multi-camera production; CaptureCat centres on screen demos, with automatic zoom from clicks, cursor smoothing, on-device English captions and share links with viewer analytics on Pro. Both record screen and camera together.",
    "pickThemWhen": "you record courses or podcasts with several cameras plus a screen share and want one app to switch and edit them.",
    "strengths": [
      "Records several cameras, mics and the screen at the same time",
      "Uses iPhones/iPads as cameras and offers AI auto-framing",
      "Exports to Final Cut (FCPXML) and YouTube chapter markers"
    ],
    "tradeoffs": [
      "Mac and iOS apps are separate purchases",
      "Built for talking-head and multi-cam shows more than cursor-driven demos",
      "Mac app updates have slowed (mostly maintenance in 2025-2026)"
    ],
    "features": [
      "Camera auto-framing only",
      null,
      "AI captions; on-device vs cloud unclear",
      false,
      null,
      "Free download, Pro subscription",
      false,
      "macOS (Apple Silicon recommended)",
      "Pro $22/mo or $149/yr (Mac App Store)"
    ],
    "switchTip": "If your videos are mostly screen walkthroughs with one camera, try CaptureCat's free tier; for multi-camera podcasts Detail may still fit better.",
    "faqExtra": {
      "question": "Does a Detail iOS subscription cover the Mac app?",
      "answer": "No. Detail says its iOS Pro subscription does not include Detail Studio Pro on macOS; they are separate apps with separate subscriptions."
    },
    "sources": [
      "https://apps.apple.com/us/app/detail-video-studio/id6443923358",
      "https://detail.co/pricing",
      "https://detail.co/download",
      "https://detail.co/duo/captions",
      "https://support.detail.co/How-do-I-record-my-screen-24546f17d979801f9617d6dd58ceda08",
      "https://support.detail.co/What-s-the-difference-between-Detail-for-Mac-and-Detail-for-iPhone-or-iPad-24546f17d97980198d67caaf5d2954f8",
      "https://detail.co/"
    ]
  },
  {
    "slug": "flashback",
    "name": "FlashBack Express",
    "website": "https://www.flashbackrecorder.com/",
    "category": "editor",
    "summary": "FlashBack Express is a Windows screen recorder with a multi-track editor; it replaced the older FlashBack Pro.",
    "differentiator": "On a Mac, CaptureCat applies zoom automatically from recorded clicks and runs captions on-device, both free. CaptureCat has no native Windows app; on Windows it runs as a browser app (Chrome/Edge 113+, Firefox 141+), and click-based auto zoom and cursor smoothing are not available there. FlashBack's paid Smart Zoom is the closer match on Windows.",
    "pickThemWhen": "you are on Windows and want a free, unwatermarked recorder with an optional low-cost editor.",
    "strengths": [
      "Free tier records screen, webcam, and audio with no time limit and no watermark.",
      "Records screen, webcam, and audio on separate tracks for editing later.",
      "Smart Zoom follows the cursor automatically within a range you place on the timeline."
    ],
    "tradeoffs": [
      "Windows only (Windows 10 and 11); no macOS version.",
      "Multi-track editing, effects, and Smart Zoom are listed under the paid plans.",
      "AI subtitles are metered: 10 minutes on the free tier, 120 on paid, then extra credits."
    ],
    "features": [
      "Cursor-follow zoom, placed manually",
      "Cursor highlight + click pulse in post",
      "Cloud AI; 10 min free, credits after",
      false,
      false,
      "Free, no watermark or time limit",
      false,
      "Windows only",
      "Free · $29/yr or $49 one-time (sale)"
    ],
    "switchTip": "FlashBack exports MP4, so finished videos carry over. Mac users get CaptureCat's full native app; Windows users should compare FlashBack's Smart Zoom against the CaptureCat browser app, which has no auto zoom.",
    "faqExtra": {
      "question": "Can I still buy FlashBack Pro?",
      "answer": "No. New FlashBack Pro licenses are no longer sold; it has been replaced by FlashBack Express, and existing customers can still renew maintenance."
    },
    "sources": [
      "https://www.flashbackrecorder.com/",
      "https://www.componentsource.com/product/bb-flashback/releases/2765231",
      "https://help.flashbackrecorder.com/article/7br945m67v-faqs",
      "https://www.flashbackrecorder.com/pricing/",
      "https://help.flashbackrecorder.com/l/en/article/1bwk6c077n-smart-zoom",
      "https://help.flashbackrecorder.com/l/en/article/t187sx5iba-highlight-the-mouse-cursor",
      "https://help.flashbackrecorder.com/l/en/article/7o82xo2vve-subtitles",
      "https://help.flashbackrecorder.com/l/en/article/4l7sroeby4-feature-credits-for-transcrptions"
    ]
  },
  {
    "slug": "kapwing",
    "name": "Kapwing",
    "website": "https://www.kapwing.com",
    "category": "editor",
    "summary": "Kapwing is a browser-based video editor for teams that includes a screen and webcam recorder inside the editor, plus AI subtitles, dubbing and repurposing tools.",
    "differentiator": "Kapwing is a collaborative general editor; CaptureCat is a dedicated screen recorder with automatic zoom from recorded clicks, cursor smoothing and click ripples, on-device captions, viewer analytics on Pro share links, and a built-in MCP server that can record and export. CaptureCat's free tier exports 4K 60 fps without a watermark.",
    "pickThemWhen": "your team edits social and marketing video together in the browser and screen recording is one input among many.",
    "strengths": [
      "Runs entirely in the browser with real-time collaborative editing",
      "Auto-subtitling, dubbing into 40+ languages, Smart Cut and transcript-based trimming",
      "Records screen, camera and audio directly inside the editor"
    ],
    "tradeoffs": [
      "Free exports carry a watermark, are limited to 720p and 4 minutes",
      "No automatic zoom or cursor effects for screen recordings",
      "Subtitles, dubbing and AI features draw on monthly credits"
    ],
    "features": [
      "Manual zoom only",
      null,
      "Auto-subtitles (location not stated)",
      "Beta MCP, invite-only testers",
      "Share links, no analytics",
      "Free, watermark, 720p, 4-min exports",
      false,
      "Browser (any OS)",
      "Free · Pro $16/mo yearly ($24 monthly) · Business $50/mo yearly"
    ],
    "switchTip": "Use CaptureCat for the recording and polish, then bring the exported MP4 into Kapwing if you still want its subtitling, dubbing or social resizing.",
    "sources": [
      "https://www.kapwing.com/pricing",
      "https://www.kapwing.com/tools/zoom",
      "https://www.kapwing.com/resources/how-to-zoom-in-on-video/",
      "https://www.kapwing.com/help/about-the-kapwing-mcp/",
      "https://www.kapwing.com/help/public-content/",
      "https://www.kapwing.com/tools/record/screen"
    ]
  },
  {
    "slug": "riverside",
    "name": "Riverside",
    "website": "https://riverside.com",
    "category": "editor",
    "summary": "Riverside is a remote recording studio for podcasts and video, with screen sharing, a text-based AI editor, live streaming and webinars.",
    "differentiator": "CaptureCat is built for solo screen videos: automatic zoom from clicks, cursor smoothing with click ripples and on-device captions, free with 4K export. Both have an MCP; Riverside's works on recordings made in its studio, while CaptureCat's can also start recordings.",
    "pickThemWhen": "you record remote interviews or podcasts and want editing, clipping and publishing in one place.",
    "strengths": [
      "Local recording of each participant in up to 4K on separate tracks",
      "Text-based editor with AI clips, show notes and filler-word removal",
      "Official MCP lets AI assistants edit, clip and publish recordings"
    ],
    "tradeoffs": [
      "Built for interviews and podcasts more than solo screen tutorials",
      "Free plan is 720p with a watermark and only 2 hours of multitrack recording",
      "MCP requires the Grow plan or higher"
    ],
    "features": [
      "Manual zoom only",
      false,
      "Cloud auto-captions",
      "Official MCP (Grow plan+)",
      "Hosting analytics on paid plans",
      "Free, 720p, watermark",
      false,
      "Browser; Mac app; iOS & Android",
      "Free · Pro $24/mo yearly ($29 monthly) · Grow $34 ($39)"
    ],
    "switchTip": "Use CaptureCat for screen demos and tutorials and keep Riverside for multi-guest recordings; Riverside exports can be imported into other editors.",
    "sources": [
      "https://riverside.com/pricing",
      "https://riverside.com/mcp",
      "https://riverside.com/recording/screen-recorder",
      "https://riverside.com/university-videos/zoom-pan-effects"
    ]
  },
  {
    "slug": "vmaker",
    "name": "Vmaker",
    "website": "https://www.vmaker.com",
    "category": "editor",
    "summary": "Vmaker AI is an AI video editor and avatar generator that also includes a screen and webcam recorder.",
    "differentiator": "CaptureCat gives unlimited recording, automatic zoom from clicks, cursor smoothing with click ripples and on-device captions free, with 4K export and no watermark. It also ships an MCP server for agents; Vmaker offers AI avatars and social repurposing that CaptureCat does not.",
    "pickThemWhen": "you want AI avatars, social clip generation and auto subtitles in the same tool as a basic recorder.",
    "strengths": [
      "Recorder bundled with an AI editor, auto subtitles and subtitle translation",
      "AI avatars, doc-to-video and long-to-short clip tools in one subscription",
      "Available on Mac, Windows, Chrome and iOS"
    ],
    "tradeoffs": [
      "Free plan limits screen recording to 1 minute and adds a watermark",
      "Subtitles, exports and recording time are metered per plan",
      "Product focus has shifted toward AI editing and avatars more than screen recording"
    ],
    "features": [
      null,
      "Mouse emphasis (paid plans)",
      "Cloud subtitles, minutes per plan",
      false,
      true,
      "Free, 1-min recordings, watermark",
      false,
      "macOS, Windows, Chrome extension, iOS",
      "Free · Starter $18/mo yearly ($24 monthly) · Teams $25 ($39)"
    ],
    "switchTip": "Export finished Vmaker videos before cancelling. Record screen tutorials in CaptureCat and keep Vmaker only if you rely on its avatars or long-to-short clipping.",
    "sources": [
      "https://www.vmaker.com/pricing",
      "https://www.vmaker.com/screen-recorder"
    ]
  },
  {
    "slug": "filmora",
    "name": "Wondershare Filmora",
    "website": "https://filmora.wondershare.com",
    "category": "editor",
    "summary": "Wondershare Filmora is a consumer video editor for Windows and Mac with a built-in screen recorder that captures screen, webcam, microphone and system audio.",
    "differentiator": "Filmora is a broad editor with a recorder attached; CaptureCat is built for screen recordings, with automatic zoom from recorded clicks, cursor smoothing, on-device captions with no credits, share links with viewer analytics on Pro, and a built-in MCP server. CaptureCat's free tier exports 4K 60 fps without a watermark; it is macOS-native, with a browser app for Windows.",
    "pickThemWhen": "you want a general-purpose video editor for YouTube and social content and screen recording is only part of the job.",
    "strengths": [
      "Full consumer video editor with effects, transitions, keyframes and a large stock asset library",
      "Screen recorder records area, window or full screen with webcam, mic and system audio",
      "Speech-to-text and animated dynamic captions in dozens of languages"
    ],
    "tradeoffs": [
      "Free version adds a watermark to every export",
      "No automatic zoom: zooms are added by hand with pan-and-zoom or keyframes",
      "AI features such as captions consume AI credits"
    ],
    "features": [
      "Manual zoom only",
      "Mouse click effects at record time",
      "Auto-captions, uses AI credits",
      false,
      false,
      "Free, watermark on export",
      false,
      "Windows & macOS",
      "Free · from US$49.99/yr · perpetual US$79.99 (sale prices)"
    ],
    "switchTip": "Record product walkthroughs in CaptureCat and keep Filmora for heavier creative editing; CaptureCat exports MP4/MOV that Filmora can import.",
    "faqExtra": {
      "question": "Does the free version of Filmora add a watermark?",
      "answer": "Yes. Wondershare says the free edition includes the basic editing features but adds a watermark to exported files."
    },
    "sources": [
      "https://filmora.wondershare.com/shop/buy/buy-video-editor.html",
      "https://filmora.wondershare.com/guide/filmora-pan-and-zoom.html",
      "https://filmora.wondershare.com/guide/record-pc-screen.html",
      "https://filmora.wondershare.com/speech-to-text.html",
      "https://filmora.wondershare.com/auto-caption.html"
    ]
  },
  {
    "slug": "cleanshot-x",
    "name": "CleanShot X",
    "website": "https://cleanshot.com",
    "category": "capture",
    "summary": "CleanShot X is a Mac screenshot and screen recording app with annotation tools, a Studio Mode video editor and CleanShot Cloud for sharing.",
    "differentiator": "CleanShot X is screenshot-first, with recording and Studio Mode added on; CaptureCat is built around recording and editing video. CaptureCat generates zooms automatically from recorded clicks, runs captions on-device, is free with no watermark, is open source under AGPL-3.0, and has an MCP server and a browser app for non-Mac users. Both offer cursor smoothing, click effects and keystroke display.",
    "pickThemWhen": "you want one Mac app for screenshots, annotation and quick recordings, and a one-time purchase matters to you.",
    "strengths": [
      "Screenshots, scrolling capture, OCR, annotation and screen recording in one Mac app",
      "Studio Mode (5.0) adds smart zooms, cursor smoothing, motion blur, backgrounds and click and keystroke display",
      "One-time $35 purchase option, with CleanShot Cloud links, comments and video transcription"
    ],
    "tradeoffs": [
      "Mac only (macOS 13+), and CleanShot says there are no plans for a Windows version",
      "No free tier or trial from CleanShot itself, only a 30-day money-back guarantee (Setapp has a 7-day trial)",
      "Basic includes one year of updates, then $19/yr to keep updating"
    ],
    "features": [
      "Manual smart zooms that follow cursor",
      true,
      "Cloud video transcription",
      "No official MCP (URL-scheme API)",
      "Share links, first-view alerts",
      "No free tier; 30-day refund",
      false,
      "macOS",
      "$35 one-time or Pro $10/user/mo yearly"
    ],
    "switchTip": "Many people keep CleanShot X for screenshots and use CaptureCat for recordings that need zooms, captions and editing. Try CaptureCat's free tier on your next tutorial before deciding whether to renew CleanShot updates.",
    "faqExtra": {
      "question": "Is there a CleanShot X free trial?",
      "answer": "CleanShot does not offer a trial; it has a 30-day money-back guarantee. The Setapp subscription that includes CleanShot has a 7-day free trial."
    },
    "sources": [
      "https://cleanshot.com/pricing",
      "https://cleanshot.com/changelog",
      "https://cleanshot.com/features",
      "https://tidbits.com/?p=75503",
      "https://glama.ai/mcp/servers/jdorfman/cleanshot-mcp",
      "https://thesweetbits.com/is-cleanshot-worth-the-upgrade/"
    ]
  },
  {
    "slug": "snagit",
    "name": "Snagit",
    "website": "https://www.techsmith.com/snagit/",
    "category": "capture",
    "summary": "Snagit by TechSmith (now branded Camtasia Snagit) is a screenshot and screen capture tool for Mac and Windows with quick video recording and step-by-step guide creation.",
    "differentiator": "Snagit is a screenshot-first tool; CaptureCat is video-first, with automatic zoom from recorded clicks, cursor smoothing and click ripples applied after recording, and on-device captions, all in a free tier. Snagit runs natively on Windows, while CaptureCat's Windows option is its browser app.",
    "pickThemWhen": "your work is mostly annotated screenshots and how-to guides, with the occasional quick screen video.",
    "strengths": [
      "Best-known for screenshots: scrolling capture, Step Capture guides and Smart Redact.",
      "Records screen, webcam, microphone and system audio, with cursor highlighting and click animations.",
      "One-click share links through TechSmith Screencast, and recordings open directly in Camtasia Editor."
    ],
    "tradeoffs": [
      "Video editing is light; deeper editing is handed off to Camtasia Editor, which watermarks exports on some plans.",
      "Cursor highlights and click animations are set before recording, not adjusted afterwards.",
      "AI captions require a Screencast Pro subscription and are English only."
    ],
    "features": [
      false,
      "Highlight & click ripple at record time",
      "Cloud, Screencast Pro only",
      false,
      "Share links, no analytics",
      "15-day free trial",
      false,
      "macOS & Windows",
      "$39/yr (Snagit Individual)"
    ],
    "switchTip": "Keep Snagit if you rely on its screenshot and Step Capture features; CaptureCat can take over the screen video work. Snagit videos are standard MP4s you can keep or re-share as-is.",
    "faqExtra": {
      "question": "Is Snagit still a one-time purchase?",
      "answer": "TechSmith's store now sells Snagit Individual as an annual subscription, and Snagit is also included in every Camtasia Suite plan, starting with Starter at the same price."
    },
    "sources": [
      "https://www.techsmith.com/snagit/",
      "https://www.techsmith.com/snagit/whats-new/",
      "https://www.techsmith.com/learn/tutorials/snagit/how-to-capture-video/",
      "https://www.techsmith.com/screencast/",
      "https://glama.ai/mcp/servers/uhli2d2bth",
      "https://support.techsmith.com/hc/en-us/articles/360040491391-Reset-Snagit-Trial-Period",
      "https://www.techsmith.com/store/snagit",
      "https://www.techsmith.com/store/camtasia/",
      "https://cursorclip.com/blog/camtasia-pricing/"
    ]
  },
  {
    "slug": "bandicam",
    "name": "Bandicam",
    "website": "https://www.bandicam.com",
    "category": "capture",
    "summary": "Bandicam is a lightweight screen, game and webcam recorder for Windows, with a separate macOS app launched in July 2025.",
    "differentiator": "Bandicam on Windows matches CaptureCat on click-based automatic zoom and has a native Windows app, which CaptureCat does not: CaptureCat on Windows is a browser app without auto zoom or cursor smoothing. On Mac, CaptureCat's free version includes auto zoom, cursor smoothing with click ripples, on-device captions and 4K 60 fps export with no time limit or watermark, plus an MCP server and, on Pro, share links with viewer analytics.",
    "pickThemWhen": "you record games or long sessions on Windows and want a light, native recorder with automatic zoom and an optional perpetual licence.",
    "strengths": [
      "Smart Zoom on Windows automatically zooms in on clicks and eases out, applied after recording",
      "Low-overhead screen and game recording, with scheduled recording and real-time drawing",
      "AI transcription exports TXT, SRT or subtitled video on Windows and Mac"
    ],
    "tradeoffs": [
      "Free version on Windows limits recordings to 10 minutes and adds a watermark; free Mac version has a 5-minute limit",
      "Built-in editing is mostly trimming; fuller editing needs Bandicut or another editor",
      "Windows and Mac are licensed separately, and there are no hosted share pages"
    ],
    "features": [
      "Smart Zoom on Windows, after recording",
      "Cursor and click highlights",
      "AI transcription; processing unstated",
      false,
      false,
      "Win: 10-min limit + watermark; Mac 5-min",
      false,
      "Windows & macOS",
      "Win from $33.26/yr or $77 once; Mac $39.99/yr"
    ],
    "switchTip": "Windows users who depend on Smart Zoom should stay on Bandicam, since CaptureCat's browser app lacks auto zoom. Mac users can record in CaptureCat instead and get auto zoom and captions in the free version.",
    "faqExtra": {
      "question": "Is Bandicam available for Mac?",
      "answer": "Yes. Bandicam Company released Bandicam for Mac in July 2025. It is sold through the Mac App Store at $9.99 per month or $39.99 per year, separately from the Windows licence."
    },
    "sources": [
      "https://www.bandicam.com/auto-zoom/",
      "https://www.bandicam.com/",
      "https://www.bandicam.com/ai-transcription/",
      "https://www.bandicam.com/blog/?p=8748",
      "https://www.bandicam.com/free-screen-recorder/",
      "https://www.bandicam.com/buy/",
      "https://www.bandicam.com/mac/",
      "https://en.wikipedia.org/wiki/Bandicam",
      "https://www.bandicam.com/mac/faqs/subscription/"
    ]
  },
  {
    "slug": "apowerrec",
    "name": "ApowerREC (Apowersoft)",
    "website": "https://www.apowersoft.com/record-all-screen",
    "category": "capture",
    "summary": "ApowerREC is Apowersoft's screen, webcam, and audio recorder for Windows and Mac, with companion mobile apps, scheduled recording, and live annotation.",
    "differentiator": "CaptureCat's free tier has no recording cap or watermark, and its native Mac app zooms automatically from clicks and transcribes on-device. CaptureCat has no native Windows app; on Windows it runs as a browser app (Chrome/Edge 113+, Firefox 141+), and click-based auto zoom and cursor smoothing are not available there.",
    "pickThemWhen": "you want a cross-platform recorder with scheduled captures and direct upload to YouTube or cloud drives.",
    "strengths": [
      "Scheduled recording tasks start and stop the screen or webcam capture automatically.",
      "Live tools during recording: annotations, an F10 zoom hotkey, an F4 spotlight, and locked-window recording.",
      "Uploads directly to YouTube, Google Drive, Dropbox, FTP, or Apowersoft's RecCloud."
    ],
    "tradeoffs": [
      "Zoom and spotlight are triggered live by hotkey, not applied automatically or adjusted after recording.",
      "Monthly and yearly plans auto-renew; the lifetime license costs $69.95.",
      "The free version is limited, and third-party sources disagree on the exact cap and whether it adds a watermark."
    ],
    "features": [
      "Manual zoom only",
      null,
      null,
      false,
      null,
      "Free version with recording time cap",
      false,
      "Windows, macOS, iOS & Android",
      "Free · from $19.95/mo or $69.95 lifetime"
    ],
    "switchTip": "Export or download anything stored in RecCloud first. On a Mac, CaptureCat replaces live hotkey zoom with automatic zoom in the editor; on Windows, the browser app has no auto zoom.",
    "faqExtra": {
      "question": "Is ApowerREC available on Mac?",
      "answer": "Yes. Apowersoft lists ApowerREC for Windows 7 or later and Mac OS X 10.10 or later, plus iOS 13 or later."
    },
    "sources": [
      "https://www.apowersoft.com/record-all-screen",
      "https://apps.apple.com/us/app/apowerrec-record-screen/id1336928544",
      "https://www.bandicam.com/blog/?p=9247",
      "https://www.g2.com/products/apowerrec/reviews",
      "https://www.techradar.com/reviews/apowerrec"
    ]
  },
  {
    "slug": "awesome-screenshot",
    "name": "Awesome Screenshot",
    "website": "https://www.awesomescreenshot.com",
    "category": "capture",
    "summary": "Awesome Screenshot is a long-running screenshot and screen-recording tool, mainly a browser extension, with desktop and iOS apps.",
    "differentiator": "CaptureCat is a video tool rather than a screenshot tool: automatic zoom from clicks, cursor smoothing with click ripples, on-device captions and 4K export are free with no watermark. Awesome Screenshot is a lightweight browser extension for annotated screenshots; CaptureCat captures full-height web pages by URL only on Pro.",
    "pickThemWhen": "you mostly need screenshots and quick browser recordings at a low price.",
    "strengths": [
      "Screenshots (including full-page) and screen recording in one cheap tool",
      "Records up to 6 hours per recording, 4K on Professional",
      "Blur, annotation and simple cut/text editing for videos"
    ],
    "tradeoffs": [
      "Free plan is limited to 20 cloud recordings at 720p (local recordings 5 min)",
      "No auto captions or transcripts",
      "Editing is basic: cut, text, shapes, blur"
    ],
    "features": [
      false,
      "Cursor highlight while recording",
      false,
      false,
      "Share links, no analytics",
      "Free, 20 cloud videos, 720p",
      false,
      "Browser extension; Mac, Windows & iOS apps",
      "Free · Professional $6/mo yearly ($8 monthly)"
    ],
    "switchTip": "Keep Awesome Screenshot for screenshots and use CaptureCat for videos; download cloud videos as MP4 before cancelling a paid plan.",
    "sources": [
      "https://www.awesomescreenshot.com/pricing",
      "https://www.awesomescreenshot.com/",
      "https://support.awesomescreenshot.com/hc/en-us"
    ]
  },
  {
    "slug": "claquette",
    "name": "Claquette",
    "website": "https://peakstep.com/claquette/",
    "category": "capture",
    "summary": "Claquette by Peakstep is a lightweight Mac app for recording the screen, camera and audio, trimming and cropping, and converting between video, GIF and audio formats.",
    "differentiator": "Claquette is a lightweight recorder and converter; CaptureCat adds automatic zoom from clicks, cursor smoothing, on-device captions and a full editor for free. Both are native Mac apps that record system audio and a camera overlay.",
    "pickThemWhen": "you want a tidy, one-time-purchase Mac utility for quick recordings and format conversion.",
    "strengths": [
      "Small native app that records screen, camera, mic and system audio",
      "Very good GIF and video conversion and compression",
      "Pro exports Final Cut Pro or Motion projects with cursor on its own lane"
    ],
    "tradeoffs": [
      "Editing is limited to trim, crop and resize",
      "No automatic zoom or captions",
      "Newest versions need macOS 15.6 or later"
    ],
    "features": [
      false,
      "Click and drag visualization",
      false,
      "No MCP; Shortcuts/App Intents",
      false,
      "Free download; paid unlocks",
      false,
      "macOS",
      "Free · Standard $19.99, Pro $29.99 one-time"
    ],
    "switchTip": "Keep Claquette for quick conversions and GIF optimisation, and use CaptureCat for demos that need zooms, captions or annotations.",
    "sources": [
      "https://apps.apple.com/us/app/claquette-gif-video-tool/id587748131?mt=12",
      "https://peakstep.com/claquette/"
    ]
  },
  {
    "slug": "ecamm-live",
    "name": "Ecamm Live",
    "website": "https://www.ecamm.com/",
    "category": "capture",
    "summary": "Ecamm Live (now branded Ecamm) is a Mac live-streaming and video production studio that also records, with scenes, overlays, screen sharing and multi-camera support.",
    "differentiator": "Ecamm is a live production studio; CaptureCat is a screen-recording editor with automatic zoom from clicks, cursor smoothing, on-device captions and an MCP server for AI agents, with a free tier. CaptureCat has no live streaming.",
    "pickThemWhen": "you stream or record live shows, interviews or webinars on a Mac and want a switcher-style studio.",
    "strengths": [
      "Strong live production: scenes, overlays, green screen and multistreaming",
      "Brings in guests (up to 10), iPhones, DSLRs, HDMI and NDI sources",
      "Pro plan records isolated audio/video tracks and works as a virtual camera in Zoom"
    ],
    "tradeoffs": [
      "Subscription only; no free tier after the trial",
      "Built for live shows, not post-production screen-demo polish",
      "No automatic zoom, cursor effects or speech captions listed"
    ],
    "features": [
      "Manual camera pan/zoom only",
      false,
      false,
      false,
      false,
      "14-day trial, watermark",
      false,
      "macOS",
      "$20/mo or $192/yr · Pro $40/mo or $384/yr"
    ],
    "switchTip": "Keep Ecamm for live streams; record product demos and tutorials in CaptureCat, where the camera bubble is on its own track for later editing.",
    "faqExtra": {
      "question": "Does Ecamm Live work on Windows?",
      "answer": "No. Ecamm is built for Mac and requires macOS 11.2 or newer."
    },
    "sources": [
      "https://appg2.ecamm.com/users/pricingplans",
      "https://www.ecamm.com/",
      "https://www.ecamm.com/mac/ecammlive/features.html"
    ]
  },
  {
    "slug": "gifox",
    "name": "Gifox",
    "website": "https://gifox.app",
    "category": "capture",
    "summary": "Gifox is a Mac menu-bar app for recording the screen to GIF (and MP4/MOV), with a frame editor and detailed GIF compression controls.",
    "differentiator": "Gifox focuses on short GIFs with excellent compression; CaptureCat is a full recorder and editor with automatic zoom, cursor smoothing, camera bubble and on-device captions, free with no time limit or watermark. Both can show keystrokes.",
    "pickThemWhen": "you mainly make short, small GIFs for docs, bug reports or chat.",
    "strengths": [
      "Very fine control over GIF size and quality",
      "Customizable mouse-click and keyboard overlays (size, shape, color, animation)",
      "Low one-time price, and also on Setapp and the Mac App Store"
    ],
    "tradeoffs": [
      "Free tier limits recordings to 10 seconds with a watermark",
      "Built for short clips; no camera, captions or automatic zoom",
      "Sharing goes to Dropbox, Google Drive or Imgur rather than hosted pages"
    ],
    "features": [
      false,
      "Click & key overlays at capture",
      false,
      false,
      false,
      "Free, 10-sec limit, watermark",
      false,
      "macOS",
      "$14.99 one-time (Pro)"
    ],
    "switchTip": "Use CaptureCat for longer walkthroughs and keep Gifox for tiny GIFs if you rely on its compression settings.",
    "faqExtra": {
      "question": "Can Gifox export MP4?",
      "answer": "Yes. Since version 2.5.0 the Gifox editor exports MP4 (H.264) and MOV (ProRes 422) in addition to GIF."
    },
    "sources": [
      "https://gifox.app/pricing",
      "https://gifox.app/",
      "https://gifox.app/changelog"
    ]
  },
  {
    "slug": "icecream-screen-recorder",
    "name": "Icecream Screen Recorder",
    "website": "https://icecreamapps.com/Screen-Recorder/",
    "category": "capture",
    "summary": "Icecream Screen Recorder is a simple screen and webcam recorder from Icecream Apps with annotations, light editing, and instant upload for sharing.",
    "differentiator": "CaptureCat's free tier has no time limit or watermark, and its native Mac app adds automatic zoom from clicks and on-device captions. CaptureCat has no native Windows app; on Windows it runs as a browser app (Chrome/Edge 113+, Firefox 141+), and click-based auto zoom and cursor smoothing are not available there.",
    "pickThemWhen": "you want a straightforward, inexpensive recorder with quick sharing and do not need a full editor.",
    "strengths": [
      "Simple recorder with live drawing, text, and arrow annotations plus trim, speed, and mute edits.",
      "One-click upload to Icecream's servers for sharing, with view counts shown in the app.",
      "Options to animate clicks, highlight the cursor, and show hotkeys used during recording."
    ],
    "tradeoffs": [
      "The free version has a recording time limit and a watermark; removing them needs PRO.",
      "Cursor and click effects are set before recording, not adjusted afterwards.",
      "No automatic zoom or auto captions."
    ],
    "features": [
      "Manual zoom only",
      "Click animation at record time",
      false,
      false,
      "Share links with view counts",
      "Free, time-limited with watermark",
      false,
      "Windows, macOS & Android",
      "Free · £19.95/yr or £49.99 lifetime (UK)"
    ],
    "switchTip": "Download any videos you still need from Icecream's cloud before switching. CaptureCat share links with view analytics need Pro, the same as Icecream's PRO plan.",
    "faqExtra": {
      "question": "Does Icecream Screen Recorder work on Mac?",
      "answer": "Yes. Icecream Apps says Screen Recorder is available on Windows, Mac, and Android."
    },
    "sources": [
      "https://icecreamapps.com/Screen-Recorder/",
      "https://icecreamapps.com/Screen-Recorder/upgrade.html",
      "https://windowsreport.com/software/icecream-screen-recorder/",
      "https://icecreamapps.com/learn/Howto/how-to-change-recording-settings.html"
    ]
  },
  {
    "slug": "ishowu",
    "name": "iShowU",
    "website": "https://www.shinywhitebox.com/ishowu-v6",
    "category": "capture",
    "summary": "iShowU V6 by shinywhitebox is a real-time Mac screen recorder that composites screen, apps, windows, cameras and iPhones into a finished video as you record.",
    "differentiator": "iShowU bakes zoom and click effects into the recording live; CaptureCat records first and applies automatic zoom from clicks, cursor smoothing and click ripples in an editor you can adjust, plus on-device captions. CaptureCat's core is free; iShowU is paid after a 7-day trial.",
    "pickThemWhen": "you want polished-looking recordings straight out of the recorder, with no editing pass.",
    "strengths": [
      "Real-time compositing: the video is ready when you stop recording",
      "Layers for screen, windows, cameras and iPhone, with AI background masks",
      "Captures app audio and mic without extra drivers; also on Setapp"
    ],
    "tradeoffs": [
      "Zoom is triggered by holding a key during recording, not added automatically afterwards",
      "Effects are baked in at record time, so they cannot be changed later in an editor",
      "No captions or hosted share links"
    ],
    "features": [
      "Manual hold-key zoom, follows mouse",
      "Click animations, rendered live",
      false,
      false,
      false,
      "7-day trial",
      false,
      "macOS",
      "$24/yr or $89 one-time"
    ],
    "switchTip": "Record a demo in CaptureCat and let it build the zooms from your clicks, then compare with your usual iShowU live-zoom take.",
    "faqExtra": {
      "question": "Does iShowU V6 support Intel Macs?",
      "answer": "Yes. Shinywhitebox lists iShowU V6 for Ventura (macOS 13) and later on Apple Silicon and Intel."
    },
    "sources": [
      "https://www.shinywhitebox.com/ishowu-v6",
      "https://www.shinywhitebox.com/store",
      "https://setapp.com/apps/ishowu",
      "https://support.shinywhitebox.com/hc/en-us/articles/33627930022937-Dynamic-Zoom-during-recording-zoom-into-areas",
      "https://support.shinywhitebox.com/hc/en-us/articles/33624860861081-Adding-mouse-animations-to-a-recording",
      "https://www.shinywhitebox.com/ishowu-studio-2"
    ]
  },
  {
    "slug": "monosnap",
    "name": "Monosnap",
    "website": "https://monosnap.ai",
    "category": "capture",
    "summary": "Monosnap is a Mac menu-bar utility for screenshots, short screen recordings and GIFs, with an image editor and its own cloud storage for sharing.",
    "differentiator": "Monosnap is screenshot-first with short screen recordings; CaptureCat is a video recorder and editor that adds automatic zoom from recorded clicks, cursor smoothing with click ripples and on-device captions, free and without a watermark. Monosnap's annotation and storage integrations for screenshots are broader than CaptureCat's.",
    "pickThemWhen": "you mostly need quick annotated screenshots and short clips uploaded to a cloud link, and video polish is secondary.",
    "strengths": [
      "Fast screenshot and annotation tool with an 8x magnifier, blur and arrows",
      "Records video and GIFs from the menu bar, free for personal use",
      "Built-in cloud storage plus uploads to Dropbox, Google Drive, S3, FTP and more"
    ],
    "tradeoffs": [
      "Free plan is non-commercial only and caps video recording at 5 minutes",
      "No automatic zoom, captions or timeline editor for videos",
      "Commercial use needs a paid plan, and web and App Store prices differ"
    ],
    "features": [
      false,
      null,
      false,
      false,
      "Share links, no analytics",
      "Free, non-commercial, 5-min video limit",
      false,
      "macOS",
      "Free · paid from $2.50/mo (web) or $4.49/mo (App Store)"
    ],
    "switchTip": "Keep Monosnap for screenshots if you like it, and use CaptureCat for anything you record as video; existing Monosnap MP4s can still be shared from Monosnap storage.",
    "faqExtra": {
      "question": "Is Monosnap free for screen recording?",
      "answer": "Monosnap's free plan is for non-commercial use and limits video recording to 5 minutes; the Non-Commercial and Commercial paid plans list unlimited video recording."
    },
    "sources": [
      "https://monosnap.ai/pay",
      "https://apps.apple.com/us/app/monosnap-screenshot-editor/id540348655?mt=12",
      "https://monosnap.ai/download/mac",
      "https://monosnap.ai/",
      "https://monosnap.com/pricing"
    ]
  },
  {
    "slug": "nimbus-capture",
    "name": "Nimbus Capture",
    "website": "https://thefusebase.com/screenshot/",
    "category": "capture",
    "summary": "Nimbus Capture is a browser extension for screenshots and screen recordings, now sold under FuseBase (formerly Nimbus Web).",
    "differentiator": "CaptureCat records natively on Mac with no time limit and adds automatic zoom from clicks, cursor smoothing and on-device captions, free with 4K export. Nimbus Capture is a lighter browser extension tied to the FuseBase workspace.",
    "pickThemWhen": "you already use FuseBase or Nimbus Note and want screenshots and short recordings inside it.",
    "strengths": [
      "Full-page screenshots, blur and annotation in the same extension",
      "Trim, crop, watermark and MP4/GIF export after recording",
      "Recordings can sit in FuseBase pages alongside files, tasks and comments"
    ],
    "tradeoffs": [
      "Free videos are limited to 5 minutes",
      "The company now focuses on FuseBase client portals and AI agents, not capture",
      "Capture pricing is not listed on the FuseBase pricing page"
    ],
    "features": [
      false,
      null,
      null,
      false,
      null,
      "Free, 5-min video limit",
      false,
      "Browser (Chrome & Edge extensions)",
      null
    ],
    "switchTip": "Export recordings as MP4 from Nimbus before switching. Keep the extension if you rely on its full-page screenshots.",
    "faqExtra": {
      "question": "Is Nimbus Capture still available?",
      "answer": "Yes, as Chrome and Edge extensions. Nimbus Web now operates as FuseBase, and nimbusweb.me redirects to thefusebase.com."
    },
    "sources": [
      "https://thefusebase.com/screenshot/",
      "https://thefusebase.com/pricing/"
    ]
  },
  {
    "slug": "nvidia-app",
    "name": "NVIDIA App (ShadowPlay)",
    "website": "https://www.nvidia.com/en-us/software/nvidia-app/",
    "category": "capture",
    "summary": "The NVIDIA App is NVIDIA's free GPU companion for Windows, and its overlay (formerly ShadowPlay in GeForce Experience) records gameplay, apps, or the desktop and keeps an Instant Replay buffer.",
    "differentiator": "The NVIDIA App is a game capture tool; CaptureCat is a recorder and editor for tutorials and demos with captions and, on Pro, share links with viewer analytics. CaptureCat has no native Windows app; on Windows it runs as a browser app (Chrome/Edge 113+, Firefox 141+), and click-based auto zoom and cursor smoothing are not available there.",
    "pickThemWhen": "you record games on an RTX PC and want instant replays at high resolution with minimal overhead.",
    "strengths": [
      "Hardware-encoded capture up to 4K HDR at 120 fps or 8K HDR at 30 fps with low performance impact, including AV1 on RTX 40 series.",
      "DVR-style Instant Replay saves the last stretch of play with Alt+Shift+F10.",
      "Records the mic as a separate audio track, with push-to-talk."
    ],
    "tradeoffs": [
      "Requires a GeForce RTX 20, 30, 40, or 50 series GPU on Windows 10 or 11.",
      "No built-in editor; captures are organised in a gallery and exported as files.",
      "Built for games; there are no zoom, cursor, or caption tools for tutorials."
    ],
    "features": [
      false,
      false,
      false,
      false,
      false,
      "Fully free (needs an RTX GPU)",
      false,
      "Windows, NVIDIA RTX GPU",
      "Free"
    ],
    "switchTip": "Most people keep the NVIDIA App for gameplay and use another tool for tutorials. On Windows that means the CaptureCat browser app; on a Mac, the native CaptureCat app adds auto zoom and cursor smoothing.",
    "faqExtra": {
      "question": "Does the NVIDIA App support GTX graphics cards?",
      "answer": "NVIDIA's system requirements list GeForce RTX 20, 30, 40, and 50 series GPUs on Windows 10 and 11."
    },
    "sources": [
      "https://www.nvidia.com/en-us/software/nvidia-app/",
      "https://www.nvidia.com/en-us/geforce/news/nvidia-app-download-and-features/",
      "https://www.nvidia.com/en-us/software/nvidia-app/system-requirements/"
    ]
  },
  {
    "slug": "obs-studio",
    "name": "OBS Studio",
    "website": "https://obsproject.com",
    "category": "free",
    "summary": "OBS Studio is a free, open-source app for recording and live streaming that composites scenes from screens, cameras, audio and other sources in real time.",
    "differentiator": "Both are free and open source. OBS is a live production and recording tool with no post-recording editor, while CaptureCat records and then edits, with automatic zoom from clicks, cursor smoothing with click ripples and on-device captions applied in post, plus a built-in MCP server.",
    "pickThemWhen": "you need live streaming or a multi-source scene setup, and want a free, open-source tool on any desktop OS.",
    "strengths": [
      "Completely free and open source (GPL-2.0), on Windows, macOS (Intel and Apple Silicon) and Linux",
      "Live streaming plus recording, with scenes, sources, transitions and a full audio mixer",
      "Large plugin ecosystem and a built-in WebSocket API for automation"
    ],
    "tradeoffs": [
      "No editor for after recording, so zooms, cursor effects and captions need another app",
      "Scene and source setup takes more learning than a single-purpose recorder",
      "No hosted share links or viewer analytics"
    ],
    "features": [
      false,
      false,
      "Experimental, Windows, live streams",
      "No; built-in WebSocket API",
      false,
      "Fully free",
      true,
      "Windows, macOS & Linux",
      "Free"
    ],
    "switchTip": "If you use OBS mainly to record tutorials and then edit elsewhere, try recording the same walkthrough in CaptureCat and compare the automatic zoom and captions against your current edit. Keep OBS for live streaming.",
    "faqExtra": {
      "question": "Is OBS Studio really free?",
      "answer": "Yes. OBS Studio is free and open source under the GPL-2.0, with no paid tier, for Windows, macOS and Linux."
    },
    "sources": [
      "https://obsproject.com/",
      "https://github.com/obsproject/obs-studio/blob/master/plugins/frontend-tools/captions.cpp",
      "https://glama.ai/mcp/servers/@royshil/obs-mcp",
      "https://github.com/obsproject/obs-studio",
      "https://obsproject.com/download",
      "https://github.com/obsproject/obs-studio/releases"
    ]
  },
  {
    "slug": "quicktime",
    "name": "QuickTime Player / macOS Screenshot (⇧⌘5)",
    "website": "https://support.apple.com/en-us/102618",
    "category": "free",
    "summary": "The Screenshot toolbar (Shift-Command-5) and QuickTime Player are the screen recording tools built into macOS, with simple trim, split and export in QuickTime Player.",
    "differentiator": "CaptureCat is also free, but adds an editor with automatic zoom from recorded clicks, cursor smoothing with click ripples, on-device captions, blur and annotations, and records system audio on macOS 14 and later. macOS's own tools need no install and, on macOS 27, can now record system audio too.",
    "pickThemWhen": "you need a quick, unedited recording and are fine with trimming in QuickTime Player.",
    "strengths": [
      "Already on every Mac, with nothing to install or pay for.",
      "Records the full screen, a window or a portion of the screen, with an optional Show Mouse Clicks circle.",
      "From macOS 27 Golden Gate, the Screenshot toolbar can record system audio via Options > Include System Audio."
    ],
    "tradeoffs": [
      "Editing is basic: trim, split, rearrange and rotate clips in QuickTime Player.",
      "No zooms, captions, camera overlay styling or share links.",
      "System audio needs macOS 27 or later; on earlier versions only microphone audio is recorded, and some apps (such as the Apple TV app) block audio capture."
    ],
    "features": [
      false,
      "Click circle at record time",
      false,
      false,
      false,
      "Fully free (built into macOS)",
      false,
      "macOS",
      "Free, included with macOS"
    ],
    "switchTip": "QuickTime and Screenshot recordings are standard .mov files, so keep using them for throwaway clips and use CaptureCat when a recording needs zooms, captions or a polished export.",
    "faqExtra": {
      "question": "Can the Mac's built-in screen recorder capture system audio?",
      "answer": "Yes, from macOS 27 Golden Gate. Press Shift-Command-5, choose a recording option, then Options > Include System Audio. On earlier macOS versions the Screenshot toolbar and QuickTime Player record microphone audio only, and some apps such as the Apple TV app can prevent their audio being captured."
    },
    "sources": [
      "https://support.apple.com/en-us/102618",
      "https://support.apple.com/guide/quicktime-player/welcome/mac",
      "https://support.apple.com/guide/mac-help/take-a-screenshot-mh26782/mac",
      "https://support.apple.com/guide/quicktime-player/trim-a-movie-or-clip-qtpf2115f6fd/mac",
      "https://support.apple.com/guide/quicktime-player/split-a-movie-into-clips-qtpa2d90df3d/mac",
      "https://www.cultofmac.com/how-to/macos-27-golden-gate-new-features",
      "https://support.apple.com/guide/quicktime-player/export-movies-qtp20e395859/mac"
    ]
  },
  {
    "slug": "kap",
    "name": "Kap",
    "website": "https://getkap.co",
    "category": "free",
    "summary": "Kap is a free, open-source macOS screen recorder built on Electron that exports short recordings as GIF, MP4, WebM or APNG.",
    "differentiator": "Like Kap, CaptureCat is free and open source (AGPL-3.0 rather than MIT), but CaptureCat is a native Swift/AppKit app rather than Electron and adds automatic zoom from recorded clicks, cursor smoothing with click ripples, on-device captions and system audio capture. CaptureCat also has a built-in MCP server so coding agents can record and edit.",
    "pickThemWhen": "you want a no-cost, open-source tool for short GIF or MP4 clips and don't need system audio, zooms or captions.",
    "strengths": [
      "Completely free and open source under the MIT licence.",
      "Exports straight to GIF, MP4, WebM and APNG, which suits quick clips for docs, issues and chat.",
      "Plugin system with community share plugins (for example Giphy, Vercel and Streamable)."
    ],
    "tradeoffs": [
      "No new release since v3.6.0 in October 2022.",
      "System audio recording is still an open feature request (GitHub issue #145); built-in audio is microphone input.",
      "Editing is limited to trimming; there is no zoom, caption or timeline editor."
    ],
    "features": [
      false,
      "Click highlights at record time",
      false,
      false,
      false,
      "Fully free",
      true,
      "macOS",
      "Free"
    ],
    "switchTip": "Both apps are free, so you can install CaptureCat alongside Kap and compare on a real recording. Kap's plugins have no CaptureCat equivalent, so keep Kap if you rely on one of them.",
    "faqExtra": {
      "question": "Is Kap still maintained?",
      "answer": "Kap's latest release on GitHub is v3.6.0, published on 27 October 2022, and the most recent commit to the main branch is from February 2024. The app still downloads and runs on macOS 12 or later for Apple silicon and Intel."
    },
    "sources": [
      "https://getkap.co",
      "https://github.com/wulkano/Kap",
      "https://api.github.com/repos/wulkano/Kap",
      "https://github.com/wulkano/Kap/releases",
      "https://github.com/wulkano/Kap/issues/145",
      "https://api.github.com/repos/wulkano/Kap/commits",
      "https://api.github.com/repos/wulkano/Kap/releases",
      "https://github.com/wulkano/Kap/blob/main/package.json"
    ]
  },
  {
    "slug": "screenity",
    "name": "Screenity",
    "website": "https://screenity.io",
    "category": "free",
    "summary": "Screenity is an open-source Chrome screen recorder extension with a paid, EU-hosted web editor for scenes, click zooms, captions and share links.",
    "differentiator": "CaptureCat includes automatic zoom from clicks, cursor smoothing and on-device captions in its free tier, while Screenity puts zoom, captions and sharing in its paid editor. Both are open source; CaptureCat's whole app is AGPL-3.0, has a native macOS app plus a browser app, exports up to 4K 60 fps, and has a built-in MCP server.",
    "pickThemWhen": "you work in Chrome on any OS and want a free open-source recorder, or a scene-based web editor with EU data hosting.",
    "strengths": [
      "Free, open-source (GPL-3.0) Chrome extension with drawing, live blur and system audio",
      "Paid editor builds videos from scenes with animated layouts, overlays and music",
      "Hosted entirely in Europe, with word-by-word captions on its own servers"
    ],
    "tradeoffs": [
      "Auto-zoom, captions, share links and MP4 export from the editor need the paid plan",
      "Pro recordings are capped at 1 hour each and editor exports at 1080p",
      "Captions are English only for now"
    ],
    "features": [
      "Yes, in the paid editor",
      "Live spotlight/ripples, not in post",
      "Cloud (EU servers), Pro only",
      false,
      "Share links (Pro), no analytics listed",
      "Free extension; editor needs Pro",
      "Extension only (GPL-3.0)",
      "Browser (Chrome extension + web app)",
      "Extension free · Pro $14/mo or $120/yr"
    ],
    "switchTip": "Download your Screenity videos as MP4 from the editor or extension before switching; scene projects do not carry over. On Chromebook or Windows, CaptureCat's browser app works in Chrome and Edge 113+.",
    "faqExtra": {
      "question": "Is Screenity still free?",
      "answer": "The Chrome extension is free and open source under GPLv3 and records screen, camera and mic. The editor with scenes, auto-zoom, captions, share links and MP4 export is a paid plan with a 7-day free trial."
    },
    "sources": [
      "https://screenity.io/",
      "https://github.com/alyssaxuu/screenity"
    ]
  },
  {
    "slug": "sharex",
    "name": "ShareX",
    "website": "https://getsharex.com",
    "category": "free",
    "summary": "ShareX is a free, open-source screenshot, screen recording and file-upload tool for Windows built around configurable capture workflows.",
    "differentiator": "Both are free and open source (ShareX under GPL-3.0, CaptureCat under AGPL-3.0). ShareX is a screenshot and upload power tool; CaptureCat is built for polished recordings, with a full editor and, on Mac, automatic zoom, cursor smoothing and on-device captions. CaptureCat has no native Windows app: on Windows it runs as a browser app, where click-based auto zoom and cursor smoothing are not available (they need a Mac recording).",
    "pickThemWhen": "you mostly need fast screenshots, short clips or GIFs on Windows, uploaded automatically to your own storage, at no cost.",
    "strengths": [
      "Completely free and open source (GPL-3.0), with no ads and no account required",
      "Highly configurable hotkeys and after-capture tasks, including OCR, annotation and scrolling capture",
      "Uploads to many destinations, including Amazon S3, Google Cloud Storage, Cloudflare R2 and custom uploaders"
    ],
    "tradeoffs": [
      "Windows only",
      "Screen recording is basic video or GIF capture with no video editor",
      "No automatic zoom, cursor effects in post, or captions"
    ],
    "features": [
      false,
      false,
      false,
      false,
      "Links via 3rd-party hosts, no analytics",
      "Fully free",
      true,
      "Windows only",
      "Free (donations accepted)"
    ],
    "switchTip": "Many people keep ShareX for screenshots and quick uploads and use CaptureCat only for recordings they want to edit. On Windows that means the CaptureCat browser app, without auto zoom or cursor smoothing.",
    "faqExtra": {
      "question": "Does ShareX work on Mac?",
      "answer": "No. ShareX describes itself as a tool for Windows, and its changelog through v21.0.0 (July 2026) adds no macOS or Linux support."
    },
    "sources": [
      "https://github.com/ShareX/ShareX",
      "https://getsharex.com/changelog",
      "https://getsharex.com/"
    ]
  },
  {
    "slug": "giphy-capture",
    "name": "GIPHY Capture",
    "website": "https://apps.apple.com/us/app/giphy-capture-the-gif-maker/id668208984?mt=12",
    "category": "free",
    "summary": "GIPHY Capture is GIPHY's free Mac app for recording short screen clips as GIFs or MP4s, with simple trimming, loop and caption-text options.",
    "differentiator": "Both are free, but GIPHY Capture makes clips of up to 30 seconds for GIFs while CaptureCat records without a time limit and adds automatic zoom, cursor smoothing, on-device speech captions and 4K 60 fps export.",
    "pickThemWhen": "you want a free, quick way to turn a few seconds of screen into a GIF.",
    "strengths": [
      "Completely free with no watermark mentioned",
      "Very simple: click to start, click to stop",
      "Animated text captions and direct upload to GIPHY"
    ],
    "tradeoffs": [
      "Clips are limited to 30 seconds",
      "No camera, audio editing, zoom or cursor effects",
      "Built for GIFs, not tutorials or product demos"
    ],
    "features": [
      false,
      false,
      false,
      false,
      "Upload to GIPHY, no analytics view",
      "Fully free, clips up to 30 sec",
      false,
      "macOS",
      "Free"
    ],
    "switchTip": "Use CaptureCat for anything longer than a quick reaction GIF; GIPHY Capture can stay installed for 30-second loops.",
    "sources": [
      "https://apps.apple.com/us/app/giphy-capture-the-gif-maker/id668208984?mt=12",
      "https://playbooks.com/mcp/microsoft-giphy"
    ]
  },
  {
    "slug": "snipping-tool",
    "name": "Windows Snipping Tool (screen recording)",
    "website": "https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b",
    "category": "free",
    "summary": "Snipping Tool is the Windows 11 screenshot app, which also records a selected screen area to video with optional system audio and microphone.",
    "differentiator": "CaptureCat adds a full editor and, on Pro, share links with viewer analytics, where Snipping Tool records and trims. CaptureCat has no native Windows app; on Windows it runs as a browser app (Chrome/Edge 113+, Firefox 141+), and click-based auto zoom and cursor smoothing are not available there.",
    "pickThemWhen": "you need a quick region recording on Windows 11 with nothing to install.",
    "strengths": [
      "Built in: press Win+Shift+R, drag a region, and record.",
      "Records PC audio and a microphone voiceover (since version 11.2307.44.0).",
      "Can trim a recording without leaving the app (since version 11.2501.7.0), with an Edit in Clipchamp button for more."
    ],
    "tradeoffs": [
      "Editing in the app is limited to trimming; captions and further edits happen in Clipchamp.",
      "Clipchamp auto-captions send audio to Azure Cognitive Services rather than running on the device.",
      "No zoom, click highlights, or cursor effects."
    ],
    "features": [
      false,
      false,
      "Cloud, via Clipchamp handoff",
      false,
      false,
      "Fully free, built into Windows 11",
      false,
      "Windows 11",
      "Free (built into Windows 11)"
    ],
    "switchTip": "Keep Snipping Tool for one-off clips. For edited walkthroughs on Windows, open the CaptureCat browser app in Chrome or Edge; projects there are stored in the cloud storage that comes with Pro.",
    "faqExtra": {
      "question": "Does Snipping Tool record audio?",
      "answer": "Yes. Since Snipping Tool version 11.2307.44.0 it can optionally record PC audio and a microphone, and you can choose the default audio settings and recording device."
    },
    "sources": [
      "https://support.microsoft.com/en-us/windows/use-snipping-tool-to-capture-screenshots-00246869-1843-655f-f220-97299b865f6b",
      "https://pureinfotech.com/snipping-tool-screen-recording-windows-11/",
      "https://blogs.windows.com/windows-insider/2025/06/19/gif-export-in-snipping-tool-begins-rolling-out-to-windows-insiders/",
      "https://support.microsoft.com/en-us/clipchamp/how-to-use-autocaptions-in-clipchamp"
    ]
  },
  {
    "slug": "xbox-game-bar",
    "name": "Xbox Game Bar",
    "website": "https://support.microsoft.com/en-us/windows/record-your-screen-with-xbox-game-bar-5328cd25-9046-4472-8a14-c485f138802c",
    "category": "free",
    "summary": "Xbox Game Bar is the overlay built into Windows 10 and 11 that records gameplay and app windows to MP4 and takes screenshots.",
    "differentiator": "CaptureCat is a recorder plus editor with captions and, on Pro, share links with viewer analytics; Game Bar only captures. CaptureCat has no native Windows app; on Windows it runs as a browser app (Chrome/Edge 113+, Firefox 141+), and click-based auto zoom and cursor smoothing are not available there.",
    "pickThemWhen": "you want a free, zero-install way to grab a game or single app window as an MP4.",
    "strengths": [
      "Already installed on Windows 10 and 11; open it with Win+G and record with Win+Alt+R.",
      "Records system audio and can include the microphone, with a hotkey to toggle the mic mid-recording.",
      "Saves plain MP4 files to Videos\\Captures, named after the app and time."
    ],
    "tradeoffs": [
      "Records one app window at a time; it cannot capture the Windows desktop or File Explorer.",
      "No editor: no trimming, zoom, click highlights, or captions.",
      "Recordings stop at a configurable maximum length (30 minutes to 4 hours)."
    ],
    "features": [
      false,
      false,
      false,
      false,
      false,
      "Fully free, built into Windows",
      false,
      "Windows 10 & 11",
      "Free (built into Windows)"
    ],
    "switchTip": "Nothing needs migrating: Game Bar recordings are ordinary MP4s in Videos\\Captures. On Windows, try the CaptureCat browser app in Chrome or Edge for full-screen or multi-window demos, keeping in mind auto zoom is a macOS-app feature.",
    "faqExtra": {
      "question": "Can Xbox Game Bar record the Windows desktop?",
      "answer": "No. Game Bar does not open on the desktop and does not work in apps such as File Explorer or Notepad; it records a single app or game window."
    },
    "sources": [
      "https://support.microsoft.com/en-us/windows/record-your-screen-with-xbox-game-bar-5328cd25-9046-4472-8a14-c485f138802c",
      "https://support.microsoft.com/af-za/help/4027180/windows-10-record-a-game-clip-with-game-bar",
      "https://www.dell.com/support/kbdoc/en-us/000103410/how-to-use-the-windows-10-game-bar-to-capture-video-from-applications",
      "https://www.elevenforum.com/t/change-max-recording-length-for-gaming-captures-in-windows-11.17924/"
    ]
  },
  {
    "slug": "arcade",
    "name": "Arcade",
    "website": "https://www.arcade.software",
    "category": "interactive",
    "summary": "Arcade is a web platform for building interactive click-through product demos and AI-generated product videos, captured with a Chrome extension or a Mac/Windows desktop app.",
    "differentiator": "Arcade mainly produces interactive click-through demos hosted on its platform; CaptureCat produces real screen-recorded video with automatic zoom from recorded clicks, on-device captions and 4K 60 fps MP4/MOV export, all free with no watermark. Both offer an MCP server and share analytics, but CaptureCat's MCP records, edits and exports video, and CaptureCat is open source (AGPL-3.0).",
    "pickThemWhen": "you want viewers to click through your product themselves on a website or in a sales email, with analytics on who engaged.",
    "strengths": [
      "Click-through HTML demos with hotspots, branching, CTAs and lead forms",
      "Automatic pan and zoom on interactive demo steps, plus AI voiceovers and auto-generated captions in the player",
      "Official MCP server for Claude that generates videos and queries demo analytics"
    ],
    "tradeoffs": [
      "Free plan allows one published demo and one published video",
      "MP4/GIF export and pan and zoom need the Growth plan; exported videos carry no captions",
      "Auto pan and zoom applies to interactive captures, not to plain video capture"
    ],
    "features": [
      "Auto in click-through demos, paid",
      null,
      "Auto, in Arcade player (not exports)",
      "Official MCP (AI videos + analytics)",
      true,
      "Free, 1 published demo + 1 video",
      false,
      "Web + Chrome ext + Mac/Windows apps",
      "Free · Growth $50/seat/mo ($42.50/mo yearly)"
    ],
    "switchTip": "Keep Arcade for embedded click-through demos and use CaptureCat when you need a narrated video file; CaptureCat's free tier exports full-quality video without a watermark, so you can try it on one walkthrough first.",
    "faqExtra": {
      "question": "Can Arcade export a demo as a video file?",
      "answer": "Yes, on the Growth plan Arcade exports demos as MP4 or GIF, but its docs say video exports do not include closed captions."
    },
    "sources": [
      "https://www.arcade.software/pricing",
      "https://docs.arcade.software/kb/build/interactive-demo/edit/pan-and-zoom",
      "https://docs.arcade.software/kb/build/interactive-demo/edit/audio.md",
      "https://docs.arcade.software/kb/build/interactive-demo/share/exports",
      "https://www.arcade.software/post/meet-the-arcade-mcp",
      "https://docs.arcade.software/kb/leverage/mcp/supported-clients/claude-code",
      "https://www.arcade.software/download"
    ]
  },
  {
    "slug": "clueso",
    "name": "Clueso",
    "website": "https://www.clueso.io",
    "category": "interactive",
    "summary": "Clueso is an AI video platform that turns screen recordings, slides and documents into narrated product videos and step-by-step help articles.",
    "differentiator": "Clueso matches CaptureCat on automatic zoom, cursor highlights and an MCP server, and adds AI voiceovers and article generation. CaptureCat runs captions on-device, exports 4K 60 fps without a watermark or a monthly export cap on its free tier, records iPhone/iPad over USB, and is open source (AGPL-3.0).",
    "pickThemWhen": "you produce training or help-center content and want AI voiceover, translation and written guides generated from one recording.",
    "strengths": [
      "Automatic zooms when recording with its Chrome extension, plus click highlights",
      "AI voiceovers (500+ voices on Free), script rewriting, translation and auto-captions on every plan",
      "Generates a step-by-step article alongside each video, and has an official MCP server on all plans"
    ],
    "tradeoffs": [
      "Free exports are capped at 10 minutes a month, 1080p, with a watermark",
      "Paid plans meter video export time (Solo: 3 hours a year)",
      "Viewership analytics and customizable players need the Business plan"
    ],
    "features": [
      true,
      "Click highlights, cursor styling",
      "Auto-captions (location not stated)",
      "Official MCP, all plans",
      "Share links; analytics Business+",
      "Free, 10 min export/mo, watermark",
      false,
      "Web + Chrome extension + desktop app",
      "Free · Solo $40/mo · Business $120/mo (billed yearly)"
    ],
    "switchTip": "If you rely on Clueso's AI voiceover and articles, keep it for that; if you narrate yourself and hit the export-minute caps, CaptureCat's free tier has no export limit or watermark.",
    "sources": [
      "https://www.clueso.io/pricing",
      "https://help.clueso.io/elements/zooms/add-zoom.md",
      "https://www.clueso.io/features/screen-recorder",
      "https://help.clueso.io/screen-recording/recording-options/highlight-color.md",
      "https://help.clueso.io/elements/captions/add-captions.md",
      "https://help.clueso.io/mcp-setup.md",
      "https://help.clueso.io/home/creation/record-screen.md"
    ]
  },
  {
    "slug": "storylane",
    "name": "Storylane",
    "website": "https://www.storylane.io",
    "category": "interactive",
    "summary": "Storylane is an interactive demo platform that captures products as screenshot or HTML demos (or video via its desktop app) and exports them as MP4 or GIF when needed.",
    "differentiator": "Storylane focuses on interactive HTML and screenshot demos with sales personalization; CaptureCat is a screen recorder and video editor with automatic zoom from recorded clicks, cursor smoothing, on-device captions and watermark-free 4K 60 fps export for free. Both offer an MCP server; CaptureCat's records, edits and exports video.",
    "pickThemWhen": "you sell a web product and want personalized, editable HTML demos on your site and in sales outreach.",
    "strengths": [
      "HTML demos that let you edit text and data inside the captured product",
      "Personalization tokens, lead forms, AI voiceovers and AI video avatars aimed at sales teams",
      "Official MCP server for Claude, ChatGPT and Copilot that builds, edits and publishes demos"
    ],
    "tradeoffs": [
      "Free plan keeps only one published demo live at a time",
      "HTML editing, A/B testing and multi-team features start on the $625/mo Growth plan",
      "Exported MP4s are view-only copies; the product is built around interactive demos, not video editing"
    ],
    "features": [
      "Auto zoom toggle on demo steps",
      null,
      null,
      "Official MCP (demos), paid plans",
      true,
      "Free, 1 live demo",
      false,
      "Web + Chrome ext + Mac/Windows apps",
      "Free · Starter $50/mo ($40/mo yearly) · Growth $625/mo"
    ],
    "switchTip": "Storylane and CaptureCat do different jobs, so many teams keep Storylane for interactive demos and use CaptureCat for narrated walkthrough videos and share links.",
    "sources": [
      "https://www.storylane.io/pricing",
      "https://docs.storylane.io/recording-demos/recording-screenshot-demos",
      "https://docs.storylane.io/editing-demos/editing-screenshot-screens",
      "https://www.storylane.io/mcp",
      "https://docs.storylane.io/changelog/august-2026/august-29-2026",
      "https://www.storylane.io/desktop-app",
      "https://docs.storylane.io/recording-demos/other-recording-options",
      "https://docs.storylane.io/sharing-demos/exports-and-downloads"
    ]
  },
  {
    "slug": "supademo",
    "name": "Supademo",
    "website": "https://supademo.com",
    "category": "interactive",
    "summary": "Supademo is a web platform for building guided interactive product demos and 4K screen-recorded videos, with AI voiceovers, demo hubs and lead analytics.",
    "differentiator": "Supademo is built around guided interactive demos for sales and marketing; CaptureCat is a video recorder and editor, with automatic zoom from recorded clicks, on-device captions and watermark-free 4K 60 fps export on its free tier. Both offer an MCP server; CaptureCat's records, edits and exports video, and CaptureCat is open source (AGPL-3.0).",
    "pickThemWhen": "your team wants interactive demos and quick recorded videos side by side, with lead capture and trackable links for sales.",
    "strengths": [
      "Generous free tier: 5 interactive demos and 50 4K video recordings",
      "Both click-through demos and screen-recorded video in one tool, with zoom and pan on every plan",
      "Official MCP server with 80+ actions across demos, analytics, voiceovers and translations"
    ],
    "tradeoffs": [
      "Free MP4 export is capped at 1080p with a watermark",
      "Analytics, closed captions, the Mac/Windows desktop apps and the MCP server require a paid plan",
      "Priced per creator seat, which adds up for larger teams"
    ],
    "features": [
      "Auto zoom option on demo steps",
      null,
      "Closed captions, paid plans",
      "Official MCP, 80+ actions, paid plans",
      "Yes, on paid plans",
      "Free: 5 demos, 50 videos, MP4 watermark",
      false,
      "Web + Chrome ext; Mac/Win app (paid)",
      "Free · Scale $50/creator/mo ($38/mo yearly) · Business $249/mo"
    ],
    "switchTip": "If you mostly use Supademo's video recordings rather than its interactive demos, record the same walkthrough in CaptureCat and compare the free 4K export with Supademo's free 1080p watermarked MP4.",
    "sources": [
      "https://supademo.com/pricing",
      "https://supademo.com/blog/auto-zoom-scroll-view-ux-improvements",
      "https://supademo.com/features/screen-recorder",
      "https://supademo.com/ai/mcp",
      "https://supademo.com/blog/product-update-mcp-server"
    ]
  },
  {
    "slug": "synthesia",
    "name": "Synthesia",
    "website": "https://www.synthesia.io",
    "category": "interactive",
    "summary": "Synthesia is an AI avatar video platform that includes an AI screen recorder browser extension for adding narrated screen captures to training and product videos.",
    "differentiator": "Synthesia centres on AI avatars and localization; CaptureCat is a screen recorder with automatic zoom from recorded clicks, cursor smoothing, on-device captions and watermark-free 4K 60 fps export on its free tier. Both offer an MCP server and share analytics; CaptureCat's MCP records and edits screen video, while Synthesia's creates avatar video drafts.",
    "pickThemWhen": "you make training or onboarding videos at scale and want AI avatars, translation and LMS export around your screen recordings.",
    "strengths": [
      "AI avatars and voice cloning can present or narrate around your screen recording",
      "Screen recorder transcribes your voiceover into an editable script, removes filler words and splits scenes",
      "Detailed video analytics (views, completion rate, watch time) on share pages and embeds"
    ],
    "tradeoffs": [
      "Zoom and pan are manual effects; no automatic click zoom",
      "Free plan is limited to 10 minutes of video a month with a watermark",
      "The recorder is a Chrome/Edge extension; recordings over 30 minutes are discouraged"
    ],
    "features": [
      "Manual zoom only",
      null,
      "Auto-captions (location not stated)",
      "Official MCP (avatar video drafts)",
      true,
      "Free, 10 min video/mo, watermark",
      false,
      "Browser (Chrome/Edge extension)",
      "Free · Starter $29/mo ($18 yearly) · Pro $89/mo ($64 yearly)"
    ],
    "switchTip": "Record and polish the screen portions in CaptureCat and keep Synthesia for avatar presenters, or switch entirely if you narrate in your own voice and do not need avatars.",
    "faqExtra": {
      "question": "Does Synthesia have a screen recorder?",
      "answer": "Yes. Synthesia's AI Screen Recorder is a Chrome or Edge extension that records a screen, window or tab, transcribes the voiceover and splits it into scenes; recordings can run up to 60 minutes."
    },
    "sources": [
      "https://www.synthesia.io/pricing",
      "https://docs.synthesia.io/docs/record",
      "https://docs.synthesia.io/reference/synthesia-mcp",
      "https://help.synthesia.io/en/articles/8271938-how-can-i-view-and-understand-video-analytics-in-synthesia",
      "https://www.synthesia.io/features/ai-screen-recorder"
    ]
  },
  {
    "slug": "trupeer",
    "name": "Trupeer",
    "website": "https://www.trupeer.ai",
    "category": "interactive",
    "summary": "Trupeer is an AI tool that turns Chrome-extension screen recordings into polished product videos with AI voiceover, auto zoom, and matching written documentation.",
    "differentiator": "Trupeer matches CaptureCat on automatic click zoom; it adds AI voiceovers and docs. CaptureCat is free with no time-limited trial, no recording-length caps and no watermark, runs captions on-device, records native apps and iPhone/iPad (not just the browser), and its MCP server can record, edit and export rather than only search.",
    "pickThemWhen": "you want an AI voice to replace your own narration and need videos and documentation generated from the same recording.",
    "strengths": [
      "Automatic zoom on every click and action, added after recording",
      "AI script polishing and voiceover in 100+ languages and accents, plus auto-generated docs",
      "Enterprise features such as SSO, SCIM, PII auto-redaction and a knowledge base"
    ],
    "tradeoffs": [
      "No ongoing free plan: the free tier lasts 10 days and exports carry a watermark",
      "Recording length is capped by plan (5 min free, 10 min Pro, 15 min Scale)",
      "Viewer analytics are Enterprise-only, and its MCP server only searches the knowledge base"
    ],
    "features": [
      true,
      null,
      "Auto-captions (location not stated)",
      "Official MCP, KB search only (Scale+)",
      "Share links; analytics Enterprise",
      "10-day free trial, watermark",
      false,
      "Browser (Chrome extension)",
      "Pro $49/mo ($40/mo yearly) · Scale $249/mo ($199 yearly)"
    ],
    "switchTip": "Record the same walkthrough in CaptureCat's free tier before your Trupeer trial ends and compare; CaptureCat keeps your own voice, so script your narration if you were relying on Trupeer's AI voiceover.",
    "sources": [
      "https://www.trupeer.ai/pricing",
      "https://www.trupeer.ai/video",
      "https://www.trupeer.ai/aiscreen-record",
      "https://trupeer.ai/mcp"
    ]
  },
  {
    "slug": "vibrantsnap",
    "name": "Vibrantsnap",
    "website": "https://www.vibrantsnap.com",
    "category": "interactive",
    "summary": "Vibrantsnap is a browser-based AI demo video tool that records with a Chrome extension, rewrites and re-voices your narration, and adds click zooms and captions.",
    "differentiator": "Vibrantsnap leans on AI script rewriting and voiceover; CaptureCat keeps your own voice and gives you automatic zoom from recorded clicks in any app (not only web pages), cursor smoothing, on-device captions and unmetered 4K 60 fps export with no watermark on its free tier, plus a built-in MCP server.",
    "pickThemWhen": "you dislike your recorded narration and want an AI voice and rewritten script for customer-facing walkthroughs.",
    "strengths": [
      "Rewrites your narration into a clean script and reads it in one of 30 studio voices across 10 languages",
      "Automatic zoom on clicks for web apps recorded through its extension",
      "No recording-length cap on any plan; free share links (with watermark)"
    ],
    "tradeoffs": [
      "Exporting a file or removing the watermark needs a paid plan, and exports are metered (25 min/mo on Pro)",
      "Auto zoom only works on web pages captured by the extension; desktop apps and imports need manual zooms",
      "Chrome-extension recorder only; no native desktop app"
    ],
    "features": [
      "Auto in web pages; manual elsewhere",
      null,
      "Auto-captions (location not stated)",
      false,
      "Share links; analytics on Pro+",
      "Free to record/edit; export paid",
      false,
      "Browser (Chrome extension)",
      "Free · Pro $49/mo ($40 yearly) · Scale $149/mo ($129 yearly)"
    ],
    "switchTip": "If you narrate well yourself, CaptureCat removes Vibrantsnap's export meter and watermark; if the AI voiceover is the reason you use Vibrantsnap, CaptureCat does not replace it.",
    "sources": [
      "https://www.vibrantsnap.com/pricing",
      "https://vibrantsnap.com/llms.txt",
      "https://www.vibrantsnap.com/blog/screen-studio-alternatives"
    ]
  }
];
