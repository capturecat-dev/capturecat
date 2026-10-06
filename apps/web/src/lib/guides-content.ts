import type { SitePage } from "./site-content";
import type { Faq } from "./pseo-content";
import { captureCatJsonLd } from "./pseo-content";
import { SITE_URL } from "./site-url";

/**
 * Job-to-be-done guides: /guides/{slug}.
 *
 * The compare and alternatives pages answer questions that name the category
 * ("best Mac screen recorder", "Screen Studio alternative"). These answer the
 * questions people ask when they describe the problem instead ("how do I make
 * my screen recording zoom in where I click"), which is where an AI answer
 * engine has no page to cite unless one exists.
 *
 * Each guide leads with a short, quotable answer, gives the honest way to do
 * it without CaptureCat where one exists, then the steps. Like the pSEO pages,
 * every guide is appended to SITE_PAGES, so it gets a Markdown twin, a sitemap
 * entry, an llms.txt line, and JSON-LD from this one record.
 *
 * Keep claims shippable: every step was checked against apps/macos (and
 * lib/feature-inventory.ts, lib/platforms.ts). Pro-only features say so.
 */

export interface GuideStep {
  name: string;
  text: string;
}

export interface Guide {
  slug: string;
  /** The question as a person would ask it. Used as the H1 and page title. */
  question: string;
  /** Meta description. */
  description: string;
  /** The direct answer, two or three sentences. Quotable on its own. */
  answer: string;
  /** The honest route without CaptureCat, when there is one. */
  without?: { title: string; text: string };
  steps: GuideStep[];
  tips?: string[];
  faqs: Faq[];
  /** Slugs of related guides. */
  related: string[];
  /** Short label for the hub and related links. */
  label: string;
  lastModified: string;
}

const CHECKED = "2026-10-06";

export const GUIDES: Guide[] = [
  {
    slug: "zoom-in-on-clicks-in-a-screen-recording",
    label: "Zoom in where you click",
    question: "How do I make a screen recording zoom in where I click on a Mac?",
    description:
      "Make a Mac screen recording zoom in automatically on your clicks and typing, with smooth cinematic motion, no keyframing. Free with CaptureCat.",
    answer:
      "Record with a screen recorder that captures your clicks as data, then let it place the zooms. CaptureCat does this for free on macOS: when you stop recording, it puts a zoom block wherever you clicked or typed, pushes in deeper on tight clusters of clicks, and holds longer while you type. Every zoom is an ordinary block on the timeline you can move, resize, or delete.",
    without: {
      title: "Doing it by hand",
      text: "In a general video editor (iMovie, Final Cut Pro, Premiere, DaVinci Resolve) you scrub to each click, add a scale and position keyframe going in, another coming out, and ease them yourself. It works, but it takes several minutes per zoom and the zoom follows wherever you set the keyframe, not the actual cursor.",
    },
    steps: [
      {
        name: "Record the screen with CaptureCat",
        text: "Pick a display, a window, or a dragged area from the menu bar icon and record as normal. Clicks, keystrokes, scrolls, and the cursor path are saved alongside the video.",
      },
      {
        name: "Stop the recording",
        text: "The editor opens with Auto Zoom already applied. Tight click clusters get a deeper push in, bursts of typing extend the hold, and any zoom blocks you placed yourself are routed around.",
      },
      {
        name: "Adjust a zoom if you want",
        text: "Each zoom is a block in the effects lane. Drag it to change timing, drag its edges to change length, set the depth anywhere from 0.3x to 6x, and drag the focal point on the preview. Turn on follow cursor to keep the zoom tracking the pointer.",
      },
      {
        name: "Pick how it moves",
        text: "Each block has five animation styles, from Instant to Cinematic. Motion blur is optional.",
      },
      {
        name: "Export",
        text: "Export MP4 or MOV up to 4K at 60 fps. The exported file uses the same maths as the preview, so the zooms land exactly where you saw them.",
      },
    ],
    tips: [
      "Click deliberately on the thing you want the viewer to look at. The zoom goes where the click was, so a stray click elsewhere creates a stray zoom.",
      "Pause briefly after a click before moving on. A short hold reads better than a zoom that immediately leaves.",
      "Zoom placement needs the click data the Mac app records. A video file recorded elsewhere has no clicks to read, so you would add the zooms manually.",
    ],
    faqs: [
      {
        question: "Is automatic zoom free in CaptureCat?",
        answer:
          "Yes. Recording, Auto Zoom, the editor, and full quality export are free with no watermark and no time limit.",
      },
      {
        question: "Can I add zooms to a video I already recorded with QuickTime?",
        answer:
          "You can add zoom blocks by hand to any imported video, but automatic placement needs the click and cursor data that CaptureCat records while you capture.",
      },
      {
        question: "Does the zoom follow the cursor?",
        answer:
          "It can. Each zoom block has a follow cursor option that keeps the zoomed frame tracking the pointer; otherwise it holds on a fixed focal point you can drag.",
      },
    ],
    related: [
      "make-a-screen-recording-look-professional",
      "smooth-cursor-in-a-screen-recording",
      "make-a-product-demo-video-on-mac",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "make-a-product-demo-video-on-mac",
    label: "Make a product demo video",
    question: "How do I make a product demo video on a Mac?",
    description:
      "A practical way to make a polished SaaS or app demo video on macOS: plan the flow, record once, let the zooms and captions apply themselves, then export or share a link.",
    answer:
      "Plan the flow, record it in one take with a recorder that captures clicks, and let the software do the editing that usually takes hours. With CaptureCat (free on macOS) the zooms, smoothed cursor, and captions are applied when you stop recording; you add a background, trim the ends, and export a 4K file or share a link.",
    steps: [
      {
        name: "Write the flow, not a script",
        text: "List the three to five things the viewer should see, in order. Reset the app to a clean state with realistic demo data so nothing private is on screen.",
      },
      {
        name: "Record the window, not the whole screen",
        text: "In CaptureCat pick the app's window as the source. Add the camera bubble and microphone if you are narrating. The camera is recorded as its own track so you can move or hide it later.",
      },
      {
        name: "Stop, and review the automatic edit",
        text: "Zooms are placed from your clicks, the cursor path is smoothed, and click ripples are available. Delete any zoom you do not want and trim the start and end.",
      },
      {
        name: "Frame it",
        text: "Pick a wallpaper or gradient, padding, rounded or squircle corners, and a shadow. Choose 16:9 for a landing page or 9:16 for social.",
      },
      {
        name: "Add captions and callouts",
        text: "Generate captions on your Mac, then add arrows, text, or a spotlight that dims everything except the button you are talking about. Blur anything sensitive you missed.",
      },
      {
        name: "Export or share",
        text: "Export MP4 or MOV up to 4K 60 fps for your site, or upload from the app for a share link with comments and viewer analytics (Pro).",
      },
    ],
    tips: [
      "Keep demos under two minutes. Speed regions on the timeline let you fast forward through loading or form filling without cutting it.",
      "Use the fake menu bar option to hide your real menu bar icons and show a clean 9:41 clock.",
      "If you use an AI coding agent, it can do the polish pass for you over CaptureCat's MCP server. See the guide on editing with AI agents.",
    ],
    faqs: [
      {
        question: "What resolution should a product demo be?",
        answer:
          "Record at your display's native Retina resolution and export 1080p for most websites, 4K if the UI has small text that viewers will want to read full screen.",
      },
      {
        question: "Do I need a separate video editor?",
        answer:
          "Not for a typical demo. CaptureCat's timeline handles trim, split, cut, speed regions, narration, annotations, captions, and camera layouts.",
      },
    ],
    related: [
      "zoom-in-on-clicks-in-a-screen-recording",
      "make-a-screen-recording-look-professional",
      "share-a-screen-recording-link-with-analytics",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "add-captions-to-a-screen-recording-on-mac",
    label: "Add captions on your Mac",
    question: "How do I add captions to a screen recording on a Mac without uploading it?",
    description:
      "Add captions or subtitles to a Mac screen recording with on-device transcription, so the audio never leaves your Mac. Styled presets and word-by-word highlighting.",
    answer:
      "Use a tool that transcribes on the device instead of in the cloud. CaptureCat transcribes your recording on your Mac with a local Whisper model, so the audio is never uploaded, then burns styled captions into the export. Captions are free and currently English.",
    without: {
      title: "Other ways",
      text: "Final Cut Pro 11 and later can transcribe speech to captions. Many other caption tools (and most online editors) upload your audio to a server to transcribe it, which matters if the recording contains anything confidential.",
    },
    steps: [
      {
        name: "Record with the microphone on",
        text: "Record your screen in CaptureCat with the mic enabled. Voice Isolation helps the transcript in a noisy room.",
      },
      {
        name: "Generate captions",
        text: "In the editor, generate captions. The speech model downloads once on first use, then runs locally on every recording after that.",
      },
      {
        name: "Fix any words",
        text: "Caption segments are editable, so you can correct product names and jargon before export.",
      },
      {
        name: "Style and place them",
        text: "Choose one of six style presets, turn on karaoke word highlighting if you want it, and drag the captions wherever they read best on the preview.",
      },
      {
        name: "Export",
        text: "Captions are rendered into the MP4 or MOV, exactly as the preview shows them.",
      },
    ],
    faqs: [
      {
        question: "Does CaptureCat send my audio anywhere for captions?",
        answer:
          "No. Transcription runs on your Mac. The model is downloaded once; your audio is not uploaded.",
      },
      {
        question: "Which languages are supported?",
        answer: "English today.",
      },
      {
        question: "Can AI agents read the transcript?",
        answer:
          "Yes. CaptureCat's MCP server has transcribe and get_transcript tools, so an agent can find a sentence and cut, speed up, or zoom around it.",
      },
    ],
    related: [
      "make-a-vertical-video-from-a-screen-recording",
      "make-a-product-demo-video-on-mac",
      "edit-a-screen-recording-with-an-ai-agent",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "record-iphone-screen-on-mac",
    label: "Record an iPhone on your Mac",
    question: "How do I record my iPhone screen on my Mac and put it in a device frame?",
    description:
      "Record an iPhone or iPad screen on a Mac over USB and export it inside a photoreal device bezel, with zooms, captions, and a background.",
    answer:
      "Plug the iPhone into the Mac with a USB cable and record it as a capture source. QuickTime Player can record it; CaptureCat records it too and wraps the export in a photoreal bezel for that model, on a background, with the same zoom, caption, and annotation tools as a Mac recording.",
    without: {
      title: "With QuickTime Player",
      text: "Connect the iPhone by cable, unlock it, open QuickTime Player, choose File > New Movie Recording, and pick the iPhone from the menu next to the record button. You get a plain video of the screen; adding a frame and background means another editor.",
    },
    steps: [
      {
        name: "Connect the iPhone or iPad",
        text: "Use a USB cable, unlock the device, and tap Trust if asked.",
      },
      {
        name: "Pick it as the source",
        text: "In CaptureCat's recording panel the device appears as its own source. Select it and record.",
      },
      {
        name: "Frame it",
        text: "The editor wraps the recording in a photoreal bezel for that model. Choose the background, padding, and shadow, and an aspect ratio such as 9:16 for social or 16:9 for a website.",
      },
      {
        name: "Polish and export",
        text: "Add zooms, captions, annotations, and tap indicators, then export MP4 or MOV.",
      },
    ],
    faqs: [
      {
        question: "Does it work wirelessly?",
        answer: "No. iPhone and iPad recording in CaptureCat is over USB.",
      },
      {
        question: "Is this useful for App Store previews?",
        answer:
          "It is useful for marketing videos and social clips. App Store preview videos have their own strict rules (no device frames, exact resolutions), so check Apple's specification before uploading.",
      },
    ],
    related: [
      "make-a-vertical-video-from-a-screen-recording",
      "make-a-screen-recording-look-professional",
      "make-a-product-demo-video-on-mac",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "blur-sensitive-information-in-a-screen-recording",
    label: "Blur sensitive information",
    question: "How do I blur an email address or API key in a screen recording?",
    description:
      "Blur or pixelate private information in a Mac screen recording after you record it: emails, API keys, customer names. Feathered edges, animated over time.",
    answer:
      "Add a blur or pixelate region over the sensitive area in the editor and set it to cover exactly the time it is on screen. In CaptureCat you drag the region directly on the preview, feather its edges, and animate it if the content moves; the blur is burned into the export.",
    steps: [
      {
        name: "Find the moment",
        text: "Scrub to where the private information first appears. Library search (Command K) reads text inside recordings with on-device OCR, which helps you find every place an email or key shows up.",
      },
      {
        name: "Add a blur region",
        text: "Add a blur in the focus lane and drag it over the area on the preview. Choose blur or pixelate and set the feather.",
      },
      {
        name: "Match it to the timeline",
        text: "Stretch the region's block on the timeline to cover the whole time the information is visible. If it moves, animate the region over time.",
      },
      {
        name: "Check before you share",
        text: "Scrub through the covered span frame by frame, then export. What you see in the preview is what is in the file.",
      },
    ],
    tips: [
      "Prevention beats blurring: use a demo account and fake data when you can.",
      "Pixelation of short text can sometimes be reversed. For keys and passwords, use a strong blur, or rotate the key after recording.",
      "A spotlight (dim everything except one area) is a softer way to steer attention without hiding content.",
    ],
    faqs: [
      {
        question: "Can I blur after recording?",
        answer: "Yes. Blur regions are added in the editor, after the recording, and can be changed any time before export.",
      },
      {
        question: "Can an AI agent add the blurs?",
        answer:
          "Yes. CaptureCat's MCP server has add_blur and remove_blur tools, and render_frames lets the agent look at the result.",
      },
    ],
    related: [
      "search-text-inside-screen-recordings",
      "make-a-product-demo-video-on-mac",
      "edit-a-screen-recording-with-an-ai-agent",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "record-screen-and-webcam-on-mac",
    label: "Screen plus webcam bubble",
    question: "How do I record my screen with my webcam in a bubble on a Mac?",
    description:
      "Record your Mac screen with a webcam bubble you can move, reshape, or hide after recording, because the camera is saved as its own track.",
    answer:
      "Turn on the camera before you record and use a recorder that saves it as a separate track, so you can fix its position later. CaptureCat records the camera as its own track: afterwards you can move the bubble, change it from a circle to a squircle or square, add a name tag, or switch to side by side or camera only for part of the video.",
    without: {
      title: "Without a dedicated recorder",
      text: "macOS can show your camera with Presenter Overlay during a screen share in supported apps, but the bubble is baked into the picture. Moving it later means re-recording.",
    },
    steps: [
      {
        name: "Turn on camera and mic",
        text: "In CaptureCat's recording panel enable the camera and microphone, choose the screen source, and record.",
      },
      {
        name: "Style the bubble",
        text: "Pick circle, squircle, rounded, or square. Drag it to any corner. Add a border, ring light, colour grade, or mirror it.",
      },
      {
        name: "Change layouts per section",
        text: "On the timeline, set spans to bubble, camera only, side by side, or screen only. Talk to the camera for the intro, then switch to the screen.",
      },
      {
        name: "Add a name tag",
        text: "A name tag pill shows your name and role next to the bubble.",
      },
    ],
    faqs: [
      {
        question: "Can I hide the webcam for part of the video?",
        answer: "Yes. Set that span to screen only on the timeline.",
      },
      {
        question: "Does it work in the browser too?",
        answer:
          "Yes. The CaptureCat browser app also records the camera as its own track.",
      },
    ],
    related: [
      "make-a-product-demo-video-on-mac",
      "share-a-screen-recording-link-with-analytics",
      "record-your-screen-on-windows-linux-or-chromebook",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "show-keyboard-shortcuts-in-a-screen-recording",
    label: "Show keyboard shortcuts",
    question: "How do I show the keyboard shortcuts I press in a screen recording?",
    description:
      "Show keyboard shortcuts on screen in a Mac screen recording as a caption-style pill, for keyboard-heavy tutorials. Only shortcuts are captured, never ordinary typing.",
    answer:
      "Use a recorder that captures your shortcuts while you record and draws them into the video. In CaptureCat, turn on Capture Shortcuts before recording and Show Shortcut Overlay in the editor: each shortcut appears as a pill at the moment you pressed it. Only combinations with Command, Control, or Option are kept, so ordinary typing such as passwords is never stored.",
    without: {
      title: "Other ways",
      text: "Standalone keystroke visualisers (KeyCastr is a popular free one) draw keys on screen while you record, so they are baked into the capture and also show plain typing unless you configure them not to.",
    },
    steps: [
      {
        name: "Turn on shortcut capture",
        text: "In the recording panel's devices menu, enable Capture Shortcuts. It is off by default and the setting sticks for future recordings.",
      },
      {
        name: "Record",
        text: "Use your shortcuts as normal. Combinations with Command, Control, or Option are recorded; everything else is discarded at capture time.",
      },
      {
        name: "Show the overlay",
        text: "In the editor's Cursor settings turn on Show Shortcut Overlay, and choose its size and position. Repeated presses collapse into one pill with a count.",
      },
      {
        name: "Add key sounds if you like",
        text: "Synthesized keyboard sounds (Thock, Clacky, Typewriter, and more) pair well with the overlay.",
      },
    ],
    faqs: [
      {
        question: "Will it show my password?",
        answer:
          "No. Only key combinations that include Command, Control, or Option are stored. Plain typing is discarded during recording.",
      },
      {
        question: "Can I turn the overlay off after recording?",
        answer: "Yes. It is a setting in the editor, not baked into the capture.",
      },
    ],
    related: [
      "smooth-cursor-in-a-screen-recording",
      "make-a-product-demo-video-on-mac",
      "zoom-in-on-clicks-in-a-screen-recording",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "smooth-cursor-in-a-screen-recording",
    label: "Smooth a shaky cursor",
    question: "How do I make the cursor move smoothly in a screen recording?",
    description:
      "Replace a jittery mouse path with a smooth, natural cursor in a Mac screen recording, without the pointer drifting off the thing you clicked.",
    answer:
      "Record the cursor as data rather than as pixels, then redraw it along a smoothed path. CaptureCat replaces the raw pointer movement with a damped spring after recording, so jitter disappears, while the click point stays on the exact pixel you clicked. You can also swap the cursor style, scale it up, and add click ripples.",
    steps: [
      {
        name: "Record with CaptureCat",
        text: "The cursor path, clicks, and scrolls are recorded separately from the screen image.",
      },
      {
        name: "Tune the smoothing",
        text: "In Cursor settings, adjust tension, friction, and mass. Higher smoothing gives slow, gliding movement; lower keeps it snappy.",
      },
      {
        name: "Pick a style",
        text: "Choose one of five cursor styles and scale it up so it reads on small screens. Personality options add tilt, stretch, and inertia.",
      },
      {
        name: "Add clicks you can see and hear",
        text: "Turn on click ripples and synthesized click sounds. Hide the cursor automatically when it is idle.",
      },
    ],
    faqs: [
      {
        question: "Does smoothing make the cursor miss what I clicked?",
        answer:
          "No. The smoothed path is constrained so the hotspot is on the recorded pixel at every click.",
      },
      {
        question: "Can I do this to a video recorded with another app?",
        answer:
          "No. Smoothing needs the cursor path, which only exists for recordings made with the CaptureCat Mac app.",
      },
    ],
    related: [
      "zoom-in-on-clicks-in-a-screen-recording",
      "show-keyboard-shortcuts-in-a-screen-recording",
      "make-a-screen-recording-look-professional",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "make-a-screen-recording-look-professional",
    label: "Make it look professional",
    question: "How do I make a screen recording look professional?",
    description:
      "The handful of changes that make a raw screen recording look polished: background and padding, zooms on the action, a smooth cursor, captions, and clean framing.",
    answer:
      "Put the recording on a background with padding and rounded corners, zoom in on the action, smooth the cursor, add captions, and hide desktop clutter. Those five changes account for most of the difference between a raw capture and a polished video, and CaptureCat applies the zooms and cursor smoothing automatically, free on macOS.",
    steps: [
      {
        name: "Clean the screen first",
        text: "Close unrelated windows, hide desktop icons, turn on Do Not Disturb, and record a window rather than the whole display.",
      },
      {
        name: "Frame it",
        text: "Add a gradient, real macOS wallpaper, or your own image behind the recording, with padding, rounded or squircle corners, and a soft shadow.",
      },
      {
        name: "Direct attention",
        text: "Keep the automatic zooms where you clicked, and add a spotlight or depth focus where you need the viewer to look at one area.",
      },
      {
        name: "Fix the cursor",
        text: "Smoothing, a larger cursor, and click ripples make every action easy to follow.",
      },
      {
        name: "Caption and trim",
        text: "Generate on-device captions, cut the dead air at the start and end, and speed up waiting.",
      },
      {
        name: "Replace the menu bar",
        text: "A clean fake menu bar with your app's name and a 9:41 clock hides your real status icons.",
      },
    ],
    faqs: [
      {
        question: "What background works best?",
        answer:
          "A soft gradient or blurred wallpaper that contrasts with the app's own colours. Avoid busy images behind text-heavy UI.",
      },
      {
        question: "Is this free?",
        answer: "Yes. All framing, zoom, cursor, and caption features in CaptureCat are free.",
      },
    ],
    related: [
      "zoom-in-on-clicks-in-a-screen-recording",
      "smooth-cursor-in-a-screen-recording",
      "add-captions-to-a-screen-recording-on-mac",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "share-a-screen-recording-link-with-analytics",
    label: "Share a link and see who watched",
    question: "How do I share a screen recording as a link and see who watched it?",
    description:
      "Share a Mac screen recording as a link instead of a file, with timestamped comments and viewer analytics: views, watch time, and retention.",
    answer:
      "Upload the recording to a host that gives you a share page with analytics instead of sending the file. CaptureCat Pro uploads straight from the Mac app and gives you a public or private link with comments pinned to the second and per-video views, watch time, and retention. The recording and editing stay free; the link is the paid part.",
    without: {
      title: "Other ways",
      text: "Loom does this for webcam-first async videos. A file in Google Drive or Dropbox gets you a link, but no idea whether anyone watched past the first ten seconds.",
    },
    steps: [
      {
        name: "Finish the edit",
        text: "Record and polish in CaptureCat as usual.",
      },
      {
        name: "Upload from the app",
        text: "Sign in with Google or Apple and upload. The share page gets an AI generated title and chapters.",
      },
      {
        name: "Choose who can see it",
        text: "Make the link public or private and copy it.",
      },
      {
        name: "Read the analytics",
        text: "See views, watch time, and retention per video, and reply to comments pinned to the exact second they refer to.",
      },
    ],
    faqs: [
      {
        question: "What happens to my links if I cancel Pro?",
        answer:
          "Links stop serving. Nothing on your Mac is touched, and resubscribing brings the same links back.",
      },
    ],
    related: [
      "make-a-product-demo-video-on-mac",
      "record-screen-and-webcam-on-mac",
      "record-your-screen-on-windows-linux-or-chromebook",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "edit-a-screen-recording-with-an-ai-agent",
    label: "Edit with Claude or Cursor",
    question: "Can Claude, ChatGPT, or Cursor edit my screen recordings?",
    description:
      "Let an AI agent (Claude Code, Codex, Cursor, Copilot, Windsurf) record, edit, and export your screen recordings through CaptureCat's built-in MCP server.",
    answer:
      "Yes, if the video tool exposes its editor to the agent. CaptureCat ships a Model Context Protocol (MCP) server inside the Mac app with 28 tools: an agent can start a recording, read where you clicked, add zooms, blurs, captions, and speed ups in one undoable batch, render frames to check its own work, and export with the same engine as the editor.",
    steps: [
      {
        name: "Connect your agent",
        text: "Open CaptureCat, click the menu bar icon, choose Connect AI Agents, and pick your client. Or run: claude mcp add capturecat -- /Applications/CaptureCat.app/Contents/MacOS/CaptureCat --mcp",
      },
      {
        name: "Close the project in the editor",
        text: "The editor autosaves, so close a project before letting an agent change it.",
      },
      {
        name: "Ask for the edit in plain language",
        text: "For example: \"Polish my latest recording: zoom on the clicks, cut the pauses longer than two seconds, blur the email in the sidebar, and export 1080p.\"",
      },
      {
        name: "Let it check its work",
        text: "The agent calls render_frames to look at the result, a single frame or a labelled contact sheet, and fixes what it sees.",
      },
      {
        name: "Undo if needed",
        text: "The last 30 agent edits can be undone, and the original media is never modified.",
      },
    ],
    tips: [
      "The server includes four ready workflows: polish a recording, tighten pacing, make a vertical social cut, and record and edit a demo.",
      "Coding agents can record a demo of the feature they just built: start_recording, drive the app, stop_recording, then edit.",
    ],
    faqs: [
      {
        question: "Which agents work?",
        answer:
          "Any MCP client. One click setup covers Claude, Codex, Cursor, VS Code (Copilot), and Windsurf.",
      },
      {
        question: "Does the agent upload my video anywhere?",
        answer:
          "No. The MCP server is the app binary running on your Mac, over stdio. The agent sees what the tools return, including frames it asks to render.",
      },
    ],
    related: [
      "make-a-vertical-video-from-a-screen-recording",
      "add-captions-to-a-screen-recording-on-mac",
      "make-a-product-demo-video-on-mac",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "make-a-vertical-video-from-a-screen-recording",
    label: "Vertical cut for TikTok and Reels",
    question: "How do I turn a screen recording into a vertical video for TikTok, Reels, or Shorts?",
    description:
      "Turn a landscape Mac screen recording into a 9:16 vertical video for TikTok, Instagram Reels, or YouTube Shorts, with tight zooms and captions so it stays readable.",
    answer:
      "Change the canvas to 9:16, then zoom in tight on the action so the UI stays readable on a phone, and add large captions. In CaptureCat that is one aspect ratio setting plus the automatic zooms from your clicks; recording a narrow window or an iPhone in the first place makes the result even better.",
    steps: [
      {
        name: "Set the aspect ratio to 9:16",
        text: "In the editor's canvas settings choose 9:16 (or 4:5 for feed posts). A landscape recording sits in the middle of the frame on your background.",
      },
      {
        name: "Zoom in deeper",
        text: "Raise the depth of the zoom blocks so the part you clicked fills the width of the phone screen.",
      },
      {
        name: "Caption it",
        text: "Most short-form video is watched muted. Generate captions and pick a bold preset.",
      },
      {
        name: "Tighten the pacing",
        text: "Cut pauses and add speed regions over waiting. Short-form viewers leave fast.",
      },
      {
        name: "Export",
        text: "Export a 9:16 MP4 at 1080 × 1920.",
      },
    ],
    tips: [
      "With an AI agent connected over MCP, the built-in \"Vertical social cut\" workflow does all of the above in one request.",
    ],
    faqs: [
      {
        question: "Do I need to re-record in portrait?",
        answer:
          "No, but it helps. Recording a narrow window or an iPhone over USB fills the vertical frame without heavy zooming.",
      },
    ],
    related: [
      "record-iphone-screen-on-mac",
      "add-captions-to-a-screen-recording-on-mac",
      "edit-a-screen-recording-with-an-ai-agent",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "record-mac-screen-with-system-audio",
    label: "Record system audio on Mac",
    question: "How do I record my Mac screen with the computer's sound, without BlackHole?",
    description:
      "Record a Mac screen recording with system audio (the sound your Mac plays) and your microphone, without installing a virtual audio driver, on any macOS version.",
    answer:
      "On macOS 27 or later, the built-in Screenshot toolbar (⇧⌘5) can do it: open Options and choose Include System Audio. On earlier versions, use a recorder built on Apple's ScreenCaptureKit, which captures system audio directly. CaptureCat records system audio and the microphone on separate tracks with no extra driver on macOS 14 and later, and lets you set their levels independently in the editor.",
    without: {
      title: "Why people install BlackHole",
      text: "Before macOS 27 the built-in screen recording only offered a microphone as the audio input, so the long-standing workaround was a virtual loopback driver such as BlackHole plus a Multi-Output Device in Audio MIDI Setup. Apple notes that some apps, such as the Apple TV app, can still block their audio from being recorded.",
    },
    steps: [
      {
        name: "Turn on system audio",
        text: "In CaptureCat's recording panel turn audio on, and enable the microphone if you are narrating.",
      },
      {
        name: "Record",
        text: "Allow Screen Recording permission when macOS asks. System audio is captured with the screen.",
      },
      {
        name: "Balance the levels",
        text: "The editor has independent faders for system audio, mic, and voice over, so a loud app does not drown out your voice.",
      },
    ],
    faqs: [
      {
        question: "Does browser recording capture system audio?",
        answer:
          "Partly. The CaptureCat browser app gets tab audio in Chrome and Edge, whole-screen audio where the operating system shares it, and none in Safari.",
      },
    ],
    related: [
      "record-screen-and-webcam-on-mac",
      "add-captions-to-a-screen-recording-on-mac",
      "record-your-screen-on-windows-linux-or-chromebook",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "record-a-full-page-website-video",
    label: "Capture a website by URL",
    question: "How do I capture a full website from a URL in desktop and mobile sizes?",
    description:
      "Capture a web page from its URL at desktop, tablet, or mobile size, full page height, in dark mode, with cookie banners and chat widgets removed.",
    answer:
      "Use a capture tool that loads the page itself at a chosen viewport instead of recording your browser window. CaptureCat captures a page by URL at desktop, tablet, or mobile size, at full page height, optionally in dark mode, and strips cookie banners and chat widgets first. Web capture by URL is part of CaptureCat Pro.",
    steps: [
      {
        name: "Choose web capture",
        text: "In CaptureCat pick the web page source and paste the URL.",
      },
      {
        name: "Pick the viewport",
        text: "Desktop, tablet, or mobile. Turn on full page height and dark mode if you need them.",
      },
      {
        name: "Capture",
        text: "Cookie banners and chat widgets are removed before the capture, so the page looks the way you designed it.",
      },
      {
        name: "Frame and export",
        text: "Put it on a background or inside a device frame and export.",
      },
    ],
    faqs: [
      {
        question: "Is this free?",
        answer: "No. Capturing web pages by URL is a CaptureCat Pro feature. Recording your own screen is free.",
      },
    ],
    related: [
      "make-a-screen-recording-look-professional",
      "record-iphone-screen-on-mac",
      "make-a-product-demo-video-on-mac",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "record-your-screen-on-windows-linux-or-chromebook",
    label: "Record on Windows, Linux, ChromeOS",
    question: "How do I record and edit a polished screen recording on Windows, Linux, or a Chromebook?",
    description:
      "Record a display, window, or tab in the browser and edit it with zooms, backgrounds, and captions on Windows, Linux, or ChromeOS, no install.",
    answer:
      "Use a browser-based recorder and editor. CaptureCat runs in Chrome, Edge, Safari 26+, or Firefox 141+: it records a display, a window, or a tab with the camera on its own track, and runs the same editor on WebGPU. Click-based zooms and cursor smoothing need a recording from the Mac app, because a browser cannot see clicks outside the page.",
    steps: [
      {
        name: "Open the recorder",
        text: "Go to app.capturecat.so/record and sign in. Browser projects are stored in CaptureCat cloud storage, which comes with Pro.",
      },
      {
        name: "Pick a source",
        text: "Choose a display, window, or tab, and turn on the camera and microphone if you want them.",
      },
      {
        name: "Edit in the browser",
        text: "Add backgrounds, padding, zoom blocks, captions, and annotations in the web editor.",
      },
      {
        name: "Export",
        text: "Export MP4 or MOV up to 4K 60 fps where your browser supports it.",
      },
    ],
    faqs: [
      {
        question: "Which browsers work?",
        answer:
          "Chrome or Edge 113+, Safari 26+, or Firefox 141+. The editor needs WebGPU. Chrome and Edge record at up to 60 fps; Safari records at its own rate, usually 30.",
      },
      {
        question: "Can I move a project between the Mac app and the browser?",
        answer: "Yes, with Open in Web Editor and Pull Web Edits.",
      },
    ],
    related: [
      "record-screen-and-webcam-on-mac",
      "share-a-screen-recording-link-with-analytics",
      "make-a-screen-recording-look-professional",
    ],
    lastModified: CHECKED,
  },
  {
    slug: "search-text-inside-screen-recordings",
    label: "Search text inside recordings",
    question: "How do I find the screen recording where a word appeared on screen?",
    description:
      "Search the text that appeared on screen inside all your Mac screen recordings and screenshots, and jump straight to the frame. On-device OCR, no upload.",
    answer:
      "Use a library that runs text recognition over your captures. CaptureCat indexes every recording and screenshot with on-device OCR; press Command K, type a word that was on screen, and the result jumps to the exact frame.",
    steps: [
      {
        name: "Record as usual",
        text: "Captures are indexed on your Mac in the background.",
      },
      {
        name: "Press Command K",
        text: "Type a word or phrase that appeared on screen: an error message, a customer name, a ticket number.",
      },
      {
        name: "Jump to the frame",
        text: "Open the result and it lands on the frame where the text was visible.",
      },
    ],
    faqs: [
      {
        question: "Is my screen content uploaded for search?",
        answer: "No. Text recognition runs on your Mac.",
      },
      {
        question: "Can an AI agent search my captures?",
        answer: "Yes, with the search_captures tool on CaptureCat's MCP server.",
      },
    ],
    related: [
      "blur-sensitive-information-in-a-screen-recording",
      "edit-a-screen-recording-with-an-ai-agent",
      "share-a-screen-recording-link-with-analytics",
    ],
    lastModified: CHECKED,
  },
];

/* ------------------------------------------------------------------ */
/* Lookups                                                             */
/* ------------------------------------------------------------------ */

export function guidePath(g: Guide): string {
  return `/guides/${g.slug}`;
}

export function findGuide(slug: string): Guide | undefined {
  return GUIDES.find((g) => g.slug === slug);
}

export function relatedGuides(g: Guide): Guide[] {
  return g.related.map(findGuide).filter((r): r is Guide => r !== undefined);
}

const HUB_LAST_MODIFIED = GUIDES.map((g) => g.lastModified).sort().at(-1)!;

/* ------------------------------------------------------------------ */
/* Markdown twins                                                      */
/* ------------------------------------------------------------------ */

function guideMarkdown(g: Guide): string {
  const parts = [`# ${g.question}`, "", g.answer, ""];
  if (g.without) parts.push(`## ${g.without.title}`, "", g.without.text, "");
  parts.push(
    "## Steps with CaptureCat",
    "",
    ...g.steps.map((s, i) => `${i + 1}. **${s.name}.** ${s.text}`),
    ""
  );
  if (g.tips?.length) parts.push("## Tips", "", ...g.tips.map((t) => `- ${t}`), "");
  parts.push(
    "## Questions",
    "",
    ...g.faqs.map((f) => `- **${f.question}** ${f.answer}`),
    ""
  );
  const related = relatedGuides(g);
  if (related.length) {
    parts.push(
      "## Related guides",
      "",
      ...related.map((r) => `- [${r.question}](${SITE_URL}${guidePath(r)})`),
      ""
    );
  }
  parts.push(
    "---",
    "",
    `[Download CaptureCat for Mac](${SITE_URL}/download) · [All guides](${SITE_URL}/guides) · [Features](${SITE_URL}/features)`,
    ""
  );
  return parts.join("\n");
}

const hubMarkdown = `# CaptureCat guides

Answers to the questions people ask when they are trying to get a screen
recording done: zooming in on clicks, captions without uploading, blurring
secrets, recording an iPhone, sharing with analytics, and letting an AI agent
do the editing.

${GUIDES.map((g) => `- [${g.question}](${SITE_URL}${guidePath(g)})`).join("\n")}

[Download CaptureCat for Mac](${SITE_URL}/download) · [Compare screen recorders](${SITE_URL}/compare)
`;

/* ------------------------------------------------------------------ */
/* JSON-LD                                                             */
/* ------------------------------------------------------------------ */

export function guideJsonLd(g: Guide): object {
  const url = `${SITE_URL}${guidePath(g)}`;
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "WebPage",
        "@id": url,
        name: g.question,
        description: g.description,
        url,
        dateModified: g.lastModified,
        breadcrumb: { "@id": `${url}#breadcrumb` },
        about: { "@id": `${SITE_URL}/#app` },
        mainEntity: { "@id": `${url}#howto` },
      },
      {
        "@type": "BreadcrumbList",
        "@id": `${url}#breadcrumb`,
        itemListElement: [
          { "@type": "ListItem", position: 1, name: "Home", item: SITE_URL },
          { "@type": "ListItem", position: 2, name: "Guides", item: `${SITE_URL}/guides` },
          { "@type": "ListItem", position: 3, name: g.label, item: url },
        ],
      },
      {
        "@type": "HowTo",
        "@id": `${url}#howto`,
        name: g.question,
        description: g.answer,
        tool: { "@id": `${SITE_URL}/#app` },
        step: g.steps.map((s, i) => ({
          "@type": "HowToStep",
          position: i + 1,
          name: s.name,
          text: s.text,
        })),
      },
      {
        "@type": "FAQPage",
        "@id": `${url}#faq`,
        mainEntity: g.faqs.map((f) => ({
          "@type": "Question",
          name: f.question,
          acceptedAnswer: { "@type": "Answer", text: f.answer },
        })),
      },
      captureCatJsonLd(),
    ],
  };
}

export function guidesHubJsonLd(): object {
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "CollectionPage",
        "@id": `${SITE_URL}/guides`,
        name: "CaptureCat guides",
        url: `${SITE_URL}/guides`,
        about: { "@id": `${SITE_URL}/#app` },
        mainEntity: { "@id": `${SITE_URL}/guides#list` },
      },
      {
        "@type": "ItemList",
        "@id": `${SITE_URL}/guides#list`,
        itemListElement: GUIDES.map((g, i) => ({
          "@type": "ListItem",
          position: i + 1,
          name: g.question,
          url: `${SITE_URL}${guidePath(g)}`,
        })),
      },
      captureCatJsonLd(),
    ],
  };
}

/* ------------------------------------------------------------------ */
/* Registry entries (consumed by site-content.ts)                      */
/* ------------------------------------------------------------------ */

export const GUIDES_HUB_DESCRIPTION =
  "How to get common screen recording jobs done on a Mac: zoom in on clicks, add captions without uploading, blur secrets, record an iPhone, record system audio, share with analytics, and edit with AI agents.";

export const GUIDE_SITE_PAGES: SitePage[] = [
  {
    path: "/guides",
    title: "Guides",
    description: GUIDES_HUB_DESCRIPTION,
    lastModified: HUB_LAST_MODIFIED,
    markdown: hubMarkdown,
  },
  ...GUIDES.map((g) => ({
    path: guidePath(g),
    title: g.question,
    description: g.description,
    lastModified: g.lastModified,
    markdown: guideMarkdown(g),
  })),
];
