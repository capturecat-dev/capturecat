/**
 * The complete user-facing feature list, grounded in the macOS codebase
 * (inventoried 2026-08-14 from apps/macos/CaptureCat — recording panel,
 * inspector panes, timeline, exporter, share pipeline, project browser,
 * MCP server). One source of truth: the homepage feature section and the
 * home page's Markdown twin both render from this.
 *
 * Keep claims shippable: nothing listed here that the app doesn't do today.
 * (Deliberately absent: GIF export — the format menu lists it but there is
 * no real GIF encoder yet.)
 */

export interface FeatureGroup {
  title: string;
  items: string[];
}

export const FEATURE_GROUPS: FeatureGroup[] = [
  {
    title: "Record",
    items: [
      "Any display, window, or dragged area — 60 fps, Retina-scale",
      "iPhone & iPad recording over USB, framed in a photoreal bezel",
      "Web page capture by URL — desktop/tablet/mobile viewports, full-page height, dark mode, cookie banners and chat widgets stripped",
      "Screenshot mode on every source",
      "Mic (with Voice Isolation), system audio, and a draggable webcam bubble recorded as its own track",
      "Clicks, cursor path, keystrokes, and scrolls captured as data — restyle them after the fact",
      "Countdown, duration limits, pause / resume / restart, and mid-recording source switching stitched into one project",
    ],
  },
  {
    title: "Auto-editing & motion",
    items: [
      "Auto Zoom reads your recorded clicks — tight clusters get a deeper push-in, typing bursts extend the hold, and your manual blocks are routed around",
      "Zoom blocks from 0.3× to 6× with a draggable focal point and follow-cursor tracking",
      "Tilt spans — 3D pitch, yaw, and roll — plus one-click Showcase moves",
      "Five animation styles per block, from Instant to Cinematic",
      "Intro slide and Curtain Unveil openers, with your logo on the curtain",
      "Motion blur and background parallax for depth",
    ],
  },
  {
    title: "Cursor & sound",
    items: [
      "Five cursor styles, size scaling, and zero-lag smoothing",
      "Fluid movement on a damped spring — tension, friction, and mass controls",
      "Cursor personality: tilt, stretch, drag, and inertia — the hotspot never leaves its pixel",
      "Click ripples plus synthesized click and keyboard sounds (Thock, Clacky, Typewriter…)",
      "Auto-hide when idle, loop-to-start for seamless loops, freeze at the end",
    ],
  },
  {
    title: "Framing & canvas",
    items: [
      "Gradients, solid colours, your own image, real macOS wallpapers, or transparent",
      "Padding, free placement, rounded / squircle / rectangle frames, soft shadows",
      "Aspect ratios from 16:9 to 9:16 to 21:9",
      "Menu bar replacement — a clean fake menu bar with your app title and the 9:41 clock",
    ],
  },
  {
    title: "Focus & privacy",
    items: [
      "Blur or pixelate regions with feathered edges — animatable over time",
      "Highlight spotlights that dim everything else",
      "Depth focus: keep one region sharp, tilt-shift the rest",
      "All of it draggable straight on the preview",
    ],
  },
  {
    title: "Camera bubble",
    items: [
      "Circle, squircle, rounded, or square — any corner or dragged anywhere",
      "Colour grades and film looks, ring light, borders, mirror, 3D tilt",
      "A name-tag pill with your name and role",
      "Per-span layouts on the timeline: bubble, camera-only, side-by-side, screen-only",
    ],
  },
  {
    title: "Annotations & captions",
    items: [
      "Text, arrows, callouts, shapes, freehand drawing, and looping tap indicators",
      "Build-in / build-out animations and spotlight backdrops",
      "Captions transcribed on device — no audio ever leaves your Mac",
      "Editable segments, karaoke word highlighting, six style presets, placed wherever you drag them",
    ],
  },
  {
    title: "Timeline & audio",
    items: [
      "Trim, split (⌘B), cut sections out, and speed regions",
      "Five lanes — video, effects, focus, annotations, voice — with snapping and full undo/redo",
      "Independent faders for system audio, mic, and voice-over",
      "Record narration straight onto the timeline as waveform clips",
    ],
  },
  {
    title: "Export & sharing",
    items: [
      "MP4 or MOV up to 4K 60 fps, quality presets with a live bitrate estimate",
      "Fast export collapses still spans for dramatically smaller files",
      "The preview and the encoder share the same math — the file is never a surprise",
      "One-click share links with viewer comments, AI titles and chapters, and per-video analytics",
    ],
  },
  {
    title: "Library & notes",
    items: [
      "Search (⌘K) reads the text inside your recordings via on-device OCR — results jump to the exact frame",
      "Folders, pins, filters, and reminders on any capture",
      "Capture highlighted text from any app as a note (⌥⌘N or the Services menu)",
    ],
  },
  {
    title: "AI agents",
    items: [
      "A built-in MCP server — the app binary itself, no plugin",
      "17 tools: start and stop recordings, search captures, add zooms and annotations, restyle, export — even render frames so the agent can see its own edits",
      "One-click setup for Claude, Codex, Cursor, VS Code, and Windsurf",
    ],
  },
  {
    title: "Native the whole way down",
    items: [
      "Swift, Metal, and AppKit — no web view, no Electron",
      "Recording 4K uses less CPU than a browser tab",
      "Menu-bar app with global shortcuts and automatic updates",
    ],
  },
];

/** The same inventory as Markdown, for the home page's /index.md twin. */
export const FEATURE_INVENTORY_MARKDOWN = FEATURE_GROUPS.map(
  (group) => `### ${group.title}\n\n${group.items.map((i) => `- ${i}`).join("\n")}`
).join("\n\n");
