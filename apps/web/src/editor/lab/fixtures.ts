/**
 * DEV-ONLY lab fixtures: synthetic clips (scripts/editor-lab/make-fixtures.sh,
 * served from the gitignored apps/web/.fixtures/) + inline project.json
 * presets. Never real user media.
 */

export interface FixtureClip {
  id: string;
  label: string;
  url: string;
}

export const FIXTURE_CLIPS: FixtureClip[] = [
  { id: "h264-1080p", label: "H.264 1080p60 (+AAC)", url: "/.fixtures/h264-1080p.mp4" },
  { id: "hevc-1080p", label: "HEVC 1080p60", url: "/.fixtures/hevc-1080p.mp4" },
  { id: "h264-4k", label: "H.264 4K60", url: "/.fixtures/h264-4k.mp4" },
  { id: "hevc-4k", label: "HEVC 4K60", url: "/.fixtures/hevc-4k.mp4" },
  { id: "hevc-1080p-p3", label: "HEVC 1080p60 Display P3", url: "/.fixtures/hevc-1080p-p3.mp4" },
];

/**
 * Normalized geometry burned into every fixture frame (make-fixtures.sh):
 * white border band = H/16; frame-index strip at the top of the content,
 * 16 cells across (bit i = cell i, LSB first; cells 12..15 = 1,0,1,0 sync),
 * height H/10.
 */
export const FIXTURE_GEOMETRY = {
  borderOfHeight: 1 / 16,
  stripHeightOfHeight: 1 / 10,
  cells: 16,
  bits: 12,
  sync: [1, 0, 1, 0],
};

/** Centre of strip cell `i` as (u, v) fractions of the video frame. */
export function stripCellCenter(i: number, videoWidth: number, videoHeight: number): [number, number] {
  const b = videoHeight * FIXTURE_GEOMETRY.borderOfHeight;
  const u = (b + ((i + 0.5) * (videoWidth - 2 * b)) / FIXTURE_GEOMETRY.cells) / videoWidth;
  const v = FIXTURE_GEOMETRY.borderOfHeight + FIXTURE_GEOMETRY.stripHeightOfHeight / 2;
  return [u, v];
}

const color = (r: number, g: number, b: number, opacity = 1) => ({ red: r, green: g, blue: b, opacity });

function project(settings: Record<string, unknown>, duration = 10) {
  // A structurally complete project.json (Mac CodingKeys) with synthetic ids.
  return {
    id: "00000000-0000-4000-8000-00000000fab1",
    name: "Lab fixture",
    createdAt: 0,
    duration,
    trimStart: 0,
    trimEnd: 0,
    zoomRegions: [],
    settings: {
      backgroundType: "Gradient",
      gradientStartColor: color(0.55, 0.23, 0.95),
      gradientEndColor: color(0.05, 0.6, 0.98),
      solidColor: color(0.08, 0.08, 0.1),
      backgroundPadding: 48,
      cornerRadius: 12,
      windowCornerRadius: 8,
      frameShape: "Rounded Rectangle",
      shadowRadius: 20,
      shadowOpacity: 0.5,
      cursorScale: 1.5,
      aspectRatio: "16:9",
      exportSettings: { format: "MP4", resolution: "1080p", fps: 60, quality: 0.85, customWidth: 1920, customHeight: 1080 },
      ...settings,
    },
  };
}

export interface ProjectPreset {
  id: string;
  label: string;
  project: ReturnType<typeof project>;
}

export const PROJECT_PRESETS: ProjectPreset[] = [
  { id: "default", label: "Defaults (legacy diagonal)", project: project({}) },
  {
    id: "angle-135",
    label: "Gradient 135°, radius 24, big shadow",
    project: project({
      gradientAngle: 135,
      gradientStartColor: color(1, 0.42, 0.21),
      gradientEndColor: color(0.33, 0.18, 0.86),
      backgroundPadding: 64,
      cornerRadius: 24,
      shadowRadius: 30,
      shadowOpacity: 0.6,
    }),
  },
  {
    id: "squircle",
    label: "Squircle 40, top-left placement",
    project: project({
      frameShape: "Squircle",
      cornerRadius: 40,
      videoPlacement: "Top Left",
      backgroundPadding: 80,
      aspectRatio: "4:3",
    }),
  },
  {
    id: "solid-rect",
    label: "Solid, rectangle frame, tight padding",
    project: project({
      backgroundType: "Solid Color",
      solidColor: color(0.93, 0.93, 0.9),
      frameShape: "Rectangle",
      windowCornerRadius: 10,
      backgroundPadding: 20,
      shadowRadius: 16,
      shadowOpacity: 0.8,
    }),
  },
  {
    id: "vertical",
    label: "9:16 vertical, gradient 90°",
    project: project({ aspectRatio: "9:16", gradientAngle: 90, backgroundPadding: 32, cornerRadius: 18 }),
  },
];
