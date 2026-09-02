/**
 * The complete user-facing feature list, grounded in the macOS codebase
 * (inventoried 2026-08-14 from apps/macos/CaptureCat: recording panel,
 * inspector panes, timeline, exporter, share pipeline, project browser,
 * MCP server). One source of truth: the feature inventory section on the
 * home and features pages and the home page's Markdown twin all render from
 * this.
 *
 * Keep claims shippable: nothing listed here that the app does not do today.
 * (Deliberately absent: GIF export. The format menu lists it but there is
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
      "Any display, window, or dragged area at 60 fps, Retina scale",
      "iPhone and iPad recording over USB, framed in a photoreal bezel",
      "Web page capture by URL: desktop, tablet, or mobile viewport, full page height, dark mode, cookie banners and chat widgets stripped",
      "Screenshot mode on every source",
      "Mic with Voice Isolation, system audio, and a draggable webcam bubble recorded as its own track",
      "Clicks, cursor path, keystrokes, and scrolls captured as data so you can restyle them afterwards",
      "Countdown, duration limits, pause, resume, restart, and mid recording source switching stitched into one project",
    ],
  },
  {
    title: "Auto editing and motion",
    items: [
      "Auto Zoom reads your recorded clicks: tight clusters get a deeper push in, typing bursts extend the hold, and your manual blocks are routed around",
      "Zoom blocks from 0.3x to 6x with a draggable focal point and follow cursor tracking",
      "Tilt spans with 3D pitch, yaw, and roll, plus one click Showcase moves",
      "Five animation styles per block, from Instant to Cinematic",
      "Intro slide and Curtain Unveil openers, with your logo on the curtain",
      "Motion blur and background parallax for depth",
    ],
  },
  {
    title: "Cursor and sound",
    items: [
      "Five cursor styles, size scaling, and zero lag smoothing",
      "Fluid movement on a damped spring with tension, friction, and mass controls",
      "Cursor personality: tilt, stretch, drag, and inertia, and the hotspot never leaves its pixel",
      "Click ripples plus synthesized click and keyboard sounds (Thock, Clacky, Typewriter and more)",
      "Keystroke overlay pill showing shortcuts as they are pressed",
      "Auto hide when idle, loop to start for seamless loops, freeze at the end",
    ],
  },
  {
    title: "Framing and canvas",
    items: [
      "Gradients, solid colours, your own image, real macOS wallpapers, or transparent",
      "Padding, free placement, rounded, squircle, or rectangle frames, soft shadows",
      "Aspect ratios from 16:9 to 9:16 to 21:9",
      "Menu bar replacement: a clean fake menu bar with your app title and the 9:41 clock",
    ],
  },
  {
    title: "Focus and privacy",
    items: [
      "Blur or pixelate regions with feathered edges, animatable over time",
      "Highlight spotlights that dim everything else",
      "Depth focus: keep one region sharp, tilt shift the rest",
      "All of it draggable straight on the preview",
    ],
  },
  {
    title: "Camera bubble",
    items: [
      "Circle, squircle, rounded, or square, in any corner or dragged anywhere",
      "Colour grades and film looks, ring light, borders, mirror, 3D tilt",
      "A name tag pill with your name and role",
      "Per span layouts on the timeline: bubble, camera only, side by side, screen only",
    ],
  },
  {
    title: "Annotations and captions",
    items: [
      "Text, arrows, callouts, shapes, freehand drawing, and looping tap indicators",
      "Build in and build out animations and spotlight backdrops",
      "Captions transcribed on device. No audio ever leaves your Mac",
      "Editable segments, karaoke word highlighting, six style presets, placed wherever you drag them",
    ],
  },
  {
    title: "Timeline and audio",
    items: [
      "Trim, split with Command B, cut sections out, and speed regions",
      "Five lanes: video, effects, focus, annotations, voice, with snapping and full undo and redo",
      "Independent faders for system audio, mic, and voice over",
      "Record narration straight onto the timeline as waveform clips",
    ],
  },
  {
    title: "Export and sharing",
    items: [
      "MP4 or MOV up to 4K 60 fps, quality presets with a live bitrate estimate",
      "Fast export collapses still spans for dramatically smaller files",
      "The preview and the encoder share the same maths, so the file is never a surprise",
      "One click share links with viewer comments, AI titles and chapters, and per video analytics",
    ],
  },
  {
    title: "Library and notes",
    items: [
      "Search with Command K reads the text inside your recordings via on device OCR, and results jump to the exact frame",
      "Folders, pins, filters, and reminders on any capture",
      "Capture highlighted text from any app as a note with Option Command N or the Services menu",
    ],
  },
  {
    title: "AI agents",
    items: [
      "A built in MCP server: the app binary itself, no plugin",
      "17 tools: start and stop recordings, search captures, add zooms and annotations, restyle, export, and render frames so the agent can see its own edits",
      "One click setup for Claude, Codex, Cursor, VS Code, and Windsurf",
    ],
  },
  {
    title: "Native the whole way down",
    items: [
      "Swift, Metal, and AppKit. No web view, no Electron",
      "Recording 4K uses less CPU than a browser tab",
      "Menu bar app with global shortcuts and automatic updates",
    ],
  },
];

/** The same inventory as Markdown, for the home page's /index.md twin. */
export const FEATURE_INVENTORY_MARKDOWN = FEATURE_GROUPS.map(
  (group) => `### ${group.title}\n\n${group.items.map((i) => `- ${i}`).join("\n")}`
).join("\n\n");
