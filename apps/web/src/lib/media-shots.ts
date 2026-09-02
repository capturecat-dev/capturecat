/**
 * Every screenshot and screen recording the marketing site wants, in one
 * place.
 *
 * Each entry renders as a <MediaPlaceholder id="..."> until you fill in
 * `src`. Drop the file into apps/web/public/media/ and set `src` to its public
 * path (for example "/media/hero-loop.mp4"). Videos autoplay muted and loop;
 * images render as plain <img>. The `shot` text is what you should record,
 * and it is shown inside the placeholder on the page so you can see what goes
 * where while browsing the site. The longer checklist lives in
 * apps/web/MEDIA-GUIDE.md.
 *
 * Recording tips that apply to every clip:
 * - Record in CaptureCat itself and export at 1080p or higher, 60 fps for the
 *   motion clips, 30 fps is fine for static screens.
 * - Keep clips between 8 and 25 seconds. They loop, so end where you began
 *   when you can.
 * - No audio is played on the site. Captions are the only thing viewers read.
 * - Use the same wallpaper and cursor style across clips so the page feels
 *   like one product, not a collage.
 */

export type ShotKind = "video" | "image";

export type ShotAspect = "16/9" | "4/3" | "3/2" | "16/10" | "1/1" | "9/16";

export interface MediaShot {
  id: ShotId;
  kind: ShotKind;
  aspect: ShotAspect;
  /** Where it appears. */
  page: "/" | "/features" | "/pricing" | "/download" | "/agents";
  /** Short label shown in the placeholder. */
  title: string;
  /** What to record, in one or two sentences. Shown on the page. */
  shot: string;
  /** Public path once you have the file, e.g. "/media/hero-loop.mp4". */
  src?: string;
  /** Optional poster for videos, e.g. "/media/hero-loop.jpg". */
  poster?: string;
  /** Alt text used once the real media is in. */
  alt: string;
}

export type ShotId =
  | "hero-loop"
  | "before-raw"
  | "before-capturecat"
  | "step-record"
  | "step-auto-edit"
  | "step-style"
  | "step-share"
  | "feature-auto-zoom"
  | "feature-cursor"
  | "feature-captions"
  | "feature-framing"
  | "feature-camera"
  | "feature-focus"
  | "feature-timeline"
  | "share-page"
  | "share-analytics"
  | "agents-connect-menu"
  | "agents-session"
  | "features-library-search"
  | "features-iphone"
  | "features-web-capture"
  | "features-annotations"
  | "features-export"
  | "features-keystrokes"
  | "download-first-launch"
  | "download-menu-bar"
  | "pricing-dashboard";

export const MEDIA_SHOTS: Record<ShotId, MediaShot> = {
  "hero-loop": {
    id: "hero-loop",
    kind: "video",
    aspect: "16/9",
    page: "/",
    title: "Hero loop",
    shot:
      "A 20 second export of a real recording: a wallpaper background, two or three auto zooms on clicks, smoothed cursor, one caption line. This is the first thing every visitor sees, so pick your best looking app.",
    alt: "A CaptureCat export playing: a Mac window on a wallpaper, zooming into a click with a caption underneath.",
  },
  "before-raw": {
    id: "before-raw",
    kind: "video",
    aspect: "16/9",
    page: "/",
    title: "Raw recording",
    shot:
      "The same 12 second task recorded with QuickTime or with every CaptureCat effect switched off. Full screen, no zoom, jittery cursor, no background.",
    alt: "A raw screen recording with no zooms, no background, and a jittery cursor.",
  },
  "before-capturecat": {
    id: "before-capturecat",
    kind: "video",
    aspect: "16/9",
    page: "/",
    title: "Same recording, exported from CaptureCat",
    shot:
      "The exact same 12 second task exported from CaptureCat with auto zoom, cursor smoothing, click ripples, and a wallpaper. Start both clips on the same frame so they play in sync.",
    alt: "The same recording after CaptureCat: zoomed on the click, smooth cursor, framed on a wallpaper.",
  },
  "step-record": {
    id: "step-record",
    kind: "image",
    aspect: "4/3",
    page: "/",
    title: "Recording panel",
    shot:
      "Screenshot of the recording panel with the source picker open, showing display, window, and area options, plus the camera and mic toggles.",
    alt: "The CaptureCat recording panel with display, window, and area sources.",
  },
  "step-auto-edit": {
    id: "step-auto-edit",
    kind: "video",
    aspect: "4/3",
    page: "/",
    title: "Zooms appear on the timeline",
    shot:
      "Stop a recording and let the editor open. Record the moment the timeline fills with zoom blocks on its own. 8 seconds is enough.",
    alt: "The editor opening after a recording, with zoom blocks already placed on the timeline.",
  },
  "step-style": {
    id: "step-style",
    kind: "video",
    aspect: "4/3",
    page: "/",
    title: "Styling in the inspector",
    shot:
      "In the inspector, change the wallpaper, then the padding, then switch on the iPhone bezel or a squircle frame. Slow deliberate clicks so each change is readable.",
    alt: "Changing wallpaper, padding, and frame in the CaptureCat inspector.",
  },
  "step-share": {
    id: "step-share",
    kind: "image",
    aspect: "4/3",
    page: "/",
    title: "Share link ready",
    shot:
      "Screenshot of the moment an upload finishes and the share link is shown with the copy button.",
    alt: "An upload finished in CaptureCat with a share link ready to copy.",
  },
  "feature-auto-zoom": {
    id: "feature-auto-zoom",
    kind: "video",
    aspect: "16/9",
    page: "/",
    title: "Auto zoom",
    shot:
      "Click into three different fields in a form or settings screen, one after another, with a second between each. Export with Auto Zoom on and the Cinematic animation style.",
    alt: "CaptureCat zooming into three form fields in turn.",
  },
  "feature-cursor": {
    id: "feature-cursor",
    kind: "video",
    aspect: "16/9",
    page: "/",
    title: "Cursor smoothing",
    shot:
      "Move the cursor across the screen in a rough, hand drawn path, click twice. Export with smoothing, a bigger cursor, and click ripples so the difference is obvious.",
    alt: "A smoothed cursor path with click ripples.",
  },
  "feature-captions": {
    id: "feature-captions",
    kind: "video",
    aspect: "16/9",
    page: "/",
    title: "Captions",
    shot:
      "Record 10 seconds of yourself narrating a click, then export with captions on and the karaoke word highlight preset. The words lighting up in time is the point of the clip.",
    alt: "On-device captions with word by word highlighting under a recording.",
  },
  "feature-framing": {
    id: "feature-framing",
    kind: "video",
    aspect: "16/9",
    page: "/",
    title: "Wallpapers and frames",
    shot:
      "Cycle through four backgrounds on the same recording: a gradient, a macOS wallpaper, a solid colour, and transparent. Then switch the aspect ratio to 9:16. Each state held for two seconds.",
    alt: "The same recording on four different backgrounds and then in a vertical frame.",
  },
  "feature-camera": {
    id: "feature-camera",
    kind: "video",
    aspect: "16/9",
    page: "/",
    title: "Camera bubble",
    shot:
      "A recording with the webcam bubble on. Move the bubble to another corner, switch the shape from circle to squircle, and show the name tag pill.",
    alt: "A webcam bubble with a name tag being moved around a recording.",
  },
  "feature-focus": {
    id: "feature-focus",
    kind: "video",
    aspect: "16/9",
    page: "/",
    title: "Blur and spotlight",
    shot:
      "A screen with an email address or API key visible. Drag a blur region over it on the preview, then add a spotlight that dims everything except one button.",
    alt: "A blur region hiding sensitive text and a spotlight dimming the rest of the screen.",
  },
  "feature-timeline": {
    id: "feature-timeline",
    kind: "video",
    aspect: "16/9",
    page: "/",
    title: "Timeline",
    shot:
      "The timeline with all five lanes visible. Split a clip with Command B, drag a zoom block wider, add a speed region. Keep the whole editor window in frame.",
    alt: "The CaptureCat timeline with video, effects, focus, annotation, and voice lanes.",
  },
  "share-page": {
    id: "share-page",
    kind: "image",
    aspect: "16/10",
    page: "/",
    title: "Share page with comments",
    shot:
      "Screenshot of a capturecat.so share page in Safari with two or three timestamped comments underneath the player. Use a real recording, not a test one.",
    alt: "A CaptureCat share page with timestamped comments below the video.",
  },
  "share-analytics": {
    id: "share-analytics",
    kind: "image",
    aspect: "16/10",
    page: "/",
    title: "Viewer analytics",
    shot:
      "Screenshot of the analytics tab for a video that has real views: the retention curve and the click heat row are the parts people look at.",
    alt: "The analytics view for a shared video showing views and watch time.",
  },
  "agents-connect-menu": {
    id: "agents-connect-menu",
    kind: "image",
    aspect: "3/2",
    page: "/agents",
    title: "Connect AI Agents menu",
    shot:
      "Screenshot of the CaptureCat menu bar menu open with the Connect AI Agents item visible, and the client picker if it opens as a sheet.",
    alt: "The Connect AI Agents item in the CaptureCat menu bar menu.",
  },
  "agents-session": {
    id: "agents-session",
    kind: "video",
    aspect: "16/9",
    page: "/agents",
    title: "An agent editing a recording",
    shot:
      "Split view: Claude Code in a terminal on the left, CaptureCat on the right. Type a request to add zooms where you clicked and export. Let the tool calls print and the zoom blocks appear in the app. 25 seconds.",
    alt: "Claude Code adding zoom effects to a CaptureCat project while the editor updates.",
  },
  "features-library-search": {
    id: "features-library-search",
    kind: "image",
    aspect: "16/10",
    page: "/features",
    title: "Library search",
    shot:
      "Screenshot of the project browser with Command K search open and a query that matches text inside a recording, with the result showing the matched frame.",
    alt: "CaptureCat library search finding text inside a recording.",
  },
  "features-iphone": {
    id: "features-iphone",
    kind: "video",
    aspect: "16/9",
    page: "/features",
    title: "iPhone recording",
    shot:
      "Record an iPhone over USB doing something simple, like opening Settings and toggling a switch. Export with the photoreal bezel on a wallpaper.",
    alt: "An iPhone recording framed in a device bezel.",
  },
  "features-web-capture": {
    id: "features-web-capture",
    kind: "image",
    aspect: "16/10",
    page: "/features",
    title: "Web capture by URL",
    shot:
      "Screenshot of the web capture panel with a URL entered, the viewport picker showing desktop, tablet, and mobile, and the full page and dark mode toggles.",
    alt: "The web capture panel with a URL and viewport options.",
  },
  "features-annotations": {
    id: "features-annotations",
    kind: "video",
    aspect: "16/9",
    page: "/features",
    title: "Annotations",
    shot:
      "Add an arrow pointing at a button, a text callout, and a looping tap indicator. Play it back so the build in animations show.",
    alt: "An arrow, a callout, and a tap indicator animating onto a recording.",
  },
  "features-export": {
    id: "features-export",
    kind: "image",
    aspect: "3/2",
    page: "/features",
    title: "Export sheet",
    shot:
      "Screenshot of the export sheet with 4K selected, the quality preset picker, and the live bitrate and file size estimate visible.",
    alt: "The CaptureCat export sheet with resolution, quality, and size estimate.",
  },
  "features-keystrokes": {
    id: "features-keystrokes",
    kind: "video",
    aspect: "16/9",
    page: "/features",
    title: "Keystroke overlay",
    shot:
      "With the keystroke overlay on, press Command K, type a few characters, then Command Enter. The pill should show each shortcut as it happens.",
    alt: "A keystroke pill showing shortcuts as they are pressed.",
  },
  "download-first-launch": {
    id: "download-first-launch",
    kind: "image",
    aspect: "3/2",
    page: "/download",
    title: "First launch",
    shot:
      "Screenshot of the first launch: the macOS screen recording permission prompt or CaptureCat's own permissions step, whichever appears first.",
    alt: "The screen recording permission prompt on first launch.",
  },
  "download-menu-bar": {
    id: "download-menu-bar",
    kind: "image",
    aspect: "3/2",
    page: "/download",
    title: "Menu bar",
    shot:
      "Screenshot of the CaptureCat menu bar icon with its menu open, cropped tight to the top right of the screen.",
    alt: "The CaptureCat menu bar menu.",
  },
  "pricing-dashboard": {
    id: "pricing-dashboard",
    kind: "image",
    aspect: "16/10",
    page: "/pricing",
    title: "Your videos dashboard",
    shot:
      "Screenshot of the web dashboard at capturecat.so/app with a handful of shared videos, view counts visible.",
    alt: "The CaptureCat web dashboard listing shared videos.",
  },
};

export const MEDIA_SHOT_LIST: MediaShot[] = Object.values(MEDIA_SHOTS);
