/**
 * Mac app vs. browser app — the comparison the home page shows and its
 * Markdown twin renders. One list, so /index.md and the page never drift.
 *
 * Every line is checked against the code that makes it true (paths from the
 * repo root). Change a claim only after changing, or re-reading, its source.
 */

export interface PlatformRow {
  label: string;
  /** What this row powers, in a few words (shown under the label). */
  note?: string;
  mac: string;
  web: string;
  /** Where the claim comes from. Not rendered. */
  sources: string[];
}

export const PLATFORM_ROWS: PlatformRow[] = [
  {
    label: "Runs on",
    mac: "macOS 14 Sonoma or later, Apple Silicon and Intel",
    web: "Chrome or Edge 113+, Safari 26+, or Firefox 141+, on Windows, Linux, ChromeOS, or a Mac. The editor needs WebGPU.",
    sources: [
      "apps/web/src/editor/ui/EditorPage.tsx (WebGPUGate)",
      "apps/web/src/components/marketing/home/Faq.tsx (Mac requirements)",
    ],
  },
  {
    label: "What it records",
    mac: "A display, a window, a dragged area, an iPhone or iPad over USB, or a web page by URL",
    web: "A display, a window, or a browser tab",
    sources: [
      "apps/macos/CaptureCat/Views/Recording/RecordingPanelMetrics.swift (RecordingSourceTab)",
      "apps/macos/CaptureCat/Services/DeviceRecorder.swift",
      "apps/web/src/editor/record/capture.ts (SurfaceKind)",
    ],
  },
  {
    label: "Camera and microphone",
    mac: "Yes, with the camera on its own track",
    web: "Yes, with the camera on its own track",
    sources: ["apps/web/src/editor/record/session.ts (camera.mov)", "apps/web/src/editor/record/capture.ts (openCamera, openMic)"],
  },
  {
    label: "System audio",
    mac: "Yes",
    web: "Tab audio in Chrome and Edge, whole-screen audio where the operating system shares it, none in Safari",
    sources: [
      "apps/macos/CaptureCat/Views/AppKitSurfaces/RecordingPanelViewController.swift (Audio On chip)",
      "apps/web/src/editor/record/useRecorder.ts (system audio notices)",
      "apps/web/src/components/dashboard/recorder-bar.tsx (No System Audio on Safari)",
    ],
  },
  {
    label: "Frame rate",
    mac: "60 fps",
    web: "Up to 60 fps in Chrome and Edge. Safari captures at its own rate, usually 30.",
    sources: [
      "apps/macos/CaptureCat/Services/ScreenRecorder.swift (minimumFrameInterval 1/60)",
      "apps/web/src/editor/record/useRecorder.ts (RECORD_FPS)",
      "apps/web/src/editor/record/capture.ts (preferFrameRate)",
    ],
  },
  {
    label: "Clicks and cursor path",
    note: "cursor smoothing, click zooms, auto zoom, ripples",
    mac: "Recorded as data during the take",
    web: "Not available. The browser burns the cursor into the video.",
    sources: ["apps/macos/CaptureCat/Services/CursorTracker.swift", "apps/web/src/editor/record/capture.ts (header comment)"],
  },
  {
    label: "Keystrokes",
    note: "keystroke pill, typing holds",
    mac: "Recorded system wide",
    web: "Not available",
    sources: ["apps/macos/CaptureCat/Services/KeystrokeTracker.swift", "apps/web/src/editor/record/capture.ts (header comment)"],
  },
  {
    label: "Editing",
    mac: "The full editor",
    web: "The web editor, on the same project file. Recordings made on the Mac keep their cursor, click, and keystroke data.",
    sources: [
      "apps/web/src/editor/ARCHITECTURE.md",
      "apps/web/src/editor/engine/passes/cursor/keystrokePass.ts",
      "apps/macos/CaptureCat/Views/AppKitSurfaces/CloudSyncController.swift (Open in Web Editor, Pull Web Edits)",
    ],
  },
  {
    label: "Export",
    mac: "MP4, MOV, or GIF, up to 4K at 60 fps",
    web: "MP4, MOV, or GIF, up to 4K at 60 fps",
    sources: ["apps/macos/CaptureCat/Models/ExportSettings.swift", "apps/web/src/editor/ui/export/exportProject.ts (EXPORT_FORMATS, EXPORT_RESOLUTIONS)"],
  },
  {
    label: "Where projects live",
    mac: "On your Mac. Free.",
    web: "In your CaptureCat cloud storage, which comes with Pro",
    sources: ["apps/api/src/routes/cloud-projects.ts (plan storage gate)", "apps/api/migrations/0008_plans.sql (free plan: no storage)"],
  },
];

export const PLATFORMS_SUMMARY =
  "Edit anywhere. Record in the browser for a quick take, or record with the Mac app when you want cursor smoothing, click zooms, and keystrokes.";

export const PLATFORMS_MARKDOWN = [
  "| | Mac app | Browser app |",
  "| --- | --- | --- |",
  ...PLATFORM_ROWS.map(
    (r) => `| **${r.label}**${r.note ? ` (${r.note})` : ""} | ${r.mac} | ${r.web} |`,
  ),
  "",
  PLATFORMS_SUMMARY,
].join("\n");
