/**
 * SF Symbol → web icon map for the editor — THE table.
 *
 * Every glyph the Mac editor UI uses (toolbar keys, rail tabs, lane glyphs,
 * pickers, menus) is listed in `SF_SYMBOLS` under its Swift name, mapped to
 * the closest `lucide-react` icon — or, where lucide has no honest match
 * (`note` says why), a small hand-drawn path. Components ask for the Mac's
 * name so web and Swift call sites read the same: <SFIcon name="scissors" />.
 *
 * Rendering is TEMPLATE-IMAGE style, like NSImageView tinting: the glyph is
 * an SVG used as a CSS mask over a `currentColor` fill, so a translucent ink
 * (the kit's white .55 muted text) composites ONCE — inline SVG strokes
 * would double up wherever fill and stroke (or two strokes) overlap.
 *
 * Sizing: SF `pointSize` P → a (1.2·P)² box; weight → stroke width in the
 * 24-unit lucide grid.
 */
import type { CSSProperties } from "react";
import {
  Aperture,
  AppWindow,
  ArrowUpRight,
  ArrowUpToLine,
  AudioLines,
  Badge,
  BadgeCheck,
  BookOpen,
  Camera,
  CaseSensitive,
  Check,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  ChevronsUpDown,
  Circle,
  Cloud,
  CloudAlert,
  CloudCheck,
  CloudOff,
  CloudUpload,
  Columns2,
  EyeOff,
  GalleryVerticalEnd,
  Grid3x3,
  Hand,
  Highlighter,
  Image,
  ImagePlus,
  Keyboard,
  Layers,
  LayoutGrid,
  Link,
  Loader,
  MessageSquare,
  MessageSquareText,
  Mic,
  MicOff,
  Minus,
  Monitor,
  Moon,
  MousePointer2,
  Palette,
  PanelRight,
  Pause,
  PenLine,
  PenTool,
  PersonStanding,
  Play,
  Pointer,
  Plus,
  RectangleHorizontal,
  Redo2,
  RefreshCw,
  Rotate3d,
  ScanSearch,
  Share,
  SkipBack,
  SkipForward,
  Square,
  SquareUser,
  Sun,
  SunMoon,
  Trash2,
  Undo2,
  UserX,
  Volume2,
  VolumeX,
  WandSparkles,
  ZoomIn,
  ZoomOut,
  type LucideIcon,
} from "lucide-react";

export type SFWeight = "regular" | "medium" | "semibold" | "bold";

interface Entry {
  /** lucide icon (outline; `fill` adds a solid fill for SF `.fill` names). */
  icon?: LucideIcon;
  /** Hand-drawn SVG body in the 24-unit grid (`sw` = stroke width). */
  svg?: (sw: number) => string;
  fill?: boolean;
  /** Box scale nudge where lucide's glyph box differs from SF's. */
  scale?: number;
  note?: string;
}

// ── Hand-drawn stand-ins (24×24 grid, stroke/fill = black; masks tint them) ──

const S = (sw: number, body: string) =>
  `<g fill="none" stroke="#000" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round">${body}</g>`;
const F = (body: string) => `<g fill="#000" stroke="none">${body}</g>`;

/** 4-point star centred (cx, cy) with radius r (concave "sparkle"). */
const star = (cx: number, cy: number, r: number) => {
  const k = r * 0.42;
  return `<path d="M${cx} ${cy - r} C${cx + k * 0.4} ${cy - k} ${cx + k} ${cy - k * 0.4} ${cx + r} ${cy} C${cx + k} ${cy + k * 0.4} ${cx + k * 0.4} ${cy + k} ${cx} ${cy + r} C${cx - k * 0.4} ${cy + k} ${cx - k} ${cy + k * 0.4} ${cx - r} ${cy} C${cx - k} ${cy - k * 0.4} ${cx - k * 0.4} ${cy - k} ${cx} ${cy - r} Z"/>`;
};

const customs = {
  sparkles: () => F(star(10.5, 14.5, 8.5) + star(18.5, 5.5, 4) + star(5, 4.5, 2.6)),
  /** SF `scope`: ring with four ticks crossing it. */
  scope: (sw: number) => S(sw, `<circle cx="12" cy="12" r="7.5"/><path d="M12 1.5 V7.5"/><path d="M12 16.5 V22.5"/><path d="M1.5 12 H7.5"/><path d="M16.5 12 H22.5"/>`),
  /** SF `scissors`: handles left, blades crossing to the right. */
  scissors: (sw: number) =>
    S(sw, `<circle cx="5.5" cy="7" r="3"/><circle cx="5.5" cy="17" r="3"/><path d="M8.2 8.4 L21 16.5"/><path d="M8.2 15.6 L21 7.5"/>`),
  /** SF `arrow.down.right.and.arrow.up.left`: two arrows meeting on the diagonal. */
  arrowsInward: (sw: number) => S(sw, `<path d="M4 4 L10 10"/><path d="M10 4.5 V10 H4.5"/><path d="M20 20 L14 14"/><path d="M14 19.5 V14 H19.5"/>`),
  /** SF `pencil.tip`: the nib — two legs meeting at the tip, the slit below it. */
  pencilTip: (sw: number) => S(sw, `<path d="M6.5 21.5 L11 4.2 Q12 2.2 13 4.2 L17.5 21.5"/><path d="M12 8.5 V13"/>`),
  /** SF `mic.fill`: solid capsule on a stand. */
  micFill: (sw: number) =>
    F(`<rect x="8.5" y="2" width="7" height="13" rx="3.5"/>`) + S(sw, `<path d="M5.5 11 a6.5 6.5 0 0 0 13 0"/><path d="M12 17.5 V21.5"/><path d="M8.5 21.5 H15.5"/>`),
  /** SF `gauge.with.needle`: dial ring + needle. */
  gauge: (sw: number) => S(sw, `<circle cx="12" cy="12" r="9"/><path d="M12 12 L8 7.5"/><path d="M12 3.5 V5"/>`) + F(`<circle cx="12" cy="12" r="1.8"/>`),
  /** SF `paintpalette.fill`: solid palette with punched paint wells. */
  paletteFill: () =>
    `<path fill="#000" fill-rule="evenodd" d="M12 2.2C6.4 2.2 2 6.2 2 11.3c0 4.9 4.1 8.9 9.1 8.9 1.5 0 2.4-.8 2.4-2 0-.6-.3-1-.6-1.4-.3-.4-.6-.8-.6-1.4 0-1.1.9-1.9 2-1.9h2.2c2.8 0 5.5-2 5.5-5.4C22 5.6 17.6 2.2 12 2.2Z M6.8 12.9a1.6 1.6 0 1 0 0-3.2 1.6 1.6 0 0 0 0 3.2Z M9 8.2a1.6 1.6 0 1 0 0-3.2 1.6 1.6 0 0 0 0 3.2Z M14.2 7a1.6 1.6 0 1 0 0-3.2 1.6 1.6 0 0 0 0 3.2Z M18 10a1.6 1.6 0 1 0 0-3.2 1.6 1.6 0 0 0 0 3.2Z"/>`,
  /** SF `cursorarrow`: the classic pointer (with its tail). */
  cursorArrow: () => F(`<path d="M7.5 3.5 L7.5 18 L10.8 14.9 L13.1 20 L15.4 19 L13.1 14 L17.5 14 Z" stroke="#000" stroke-width="0.9" stroke-linejoin="round"/>`),
  /** SF `figure.walk.motion`: walker with trailing motion lines. */
  walkMotion: (sw: number) =>
    F(`<circle cx="14.5" cy="3.9" r="2"/>`) +
    S(sw, `<path d="M13.5 8 L11.5 14 L14.5 17 L15.5 21.5"/><path d="M11.5 14 L9.5 21.5"/><path d="M13.5 8 L16.8 11.2 L19.5 12"/><path d="M13.5 8 L10.5 10 L9 13"/><path d="M3 9.5 H7"/><path d="M2.5 13 H6.5"/><path d="M3.5 16.5 H7"/>`),
  /** SF `scribble`: one looping freehand stroke. */
  scribble: (sw: number) =>
    S(sw, `<path d="M3 17.5 C6 9 9 5.5 10.5 7.5 C12 9.5 7 16 9 17.5 C11 19 14 10 16 10.5 C18 11 15 17 17 17.5 C18.5 18 20 15.5 21 14"/>`),
  /** SF `captions.bubble`: speech bubble with two caption lines. */
  captionsBubble: (sw: number) =>
    S(sw, `<path d="M5 3.5 H19 A2.5 2.5 0 0 1 21.5 6 V14.5 A2.5 2.5 0 0 1 19 17 H10 L6 20.5 V17 H5 A2.5 2.5 0 0 1 2.5 14.5 V6 A2.5 2.5 0 0 1 5 3.5 Z"/><path d="M6.5 9 H12"/><path d="M14.5 9 H17.5"/><path d="M6.5 12.5 H9.5"/><path d="M12 12.5 H17.5"/>`),
  /** Filled bubble with the caption lines PUNCHED out (luminance mask). */
  captionsBubbleFill: (sw: number) =>
    `<defs><mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24"><rect width="24" height="24" fill="#fff"/>` +
    `<g stroke="#000" stroke-width="${sw}" stroke-linecap="round"><path d="M6.5 9 H12"/><path d="M14.5 9 H17.5"/><path d="M6.5 12.5 H9.5"/><path d="M12 12.5 H17.5"/></g></mask></defs>` +
    `<path mask="url(#m)" fill="#000" d="M5 3.5 H19 A2.5 2.5 0 0 1 21.5 6 V14.5 A2.5 2.5 0 0 1 19 17 H10 L6 20.5 V17 H5 A2.5 2.5 0 0 1 2.5 14.5 V6 A2.5 2.5 0 0 1 5 3.5 Z"/>`,
  /** SF `square.fill.on.square`: a solid square in front of an outlined one (back-top-right). */
  squareFillOnSquare: (sw: number) =>
    S(sw, `<path d="M8.5 5.5 V4.5 A2 2 0 0 1 10.5 2.5 H19.5 A2 2 0 0 1 21.5 4.5 V13.5 A2 2 0 0 1 19.5 15.5 H18.5"/>`) +
    F(`<rect x="2.5" y="8.5" width="13" height="13" rx="2.5"/>`),
};

/**
 * The table. Keys are SF Symbol names exactly as the Swift sources spell them.
 */
export const SF_SYMBOLS: Record<string, Entry> = {
  // ── Transport (TimelineViewController.buildToolbar) ──
  "backward.end.fill": { icon: SkipBack, fill: true },
  "forward.end.fill": { icon: SkipForward, fill: true },
  "play.fill": { icon: Play, fill: true },
  "pause.fill": { icon: Pause, fill: true },
  "stop.fill": { icon: Square, fill: true, scale: 0.85 },
  "arrow.uturn.backward": { icon: Undo2 },
  "arrow.uturn.forward": { icon: Redo2 },
  trash: { icon: Trash2 },
  sparkles: { svg: customs.sparkles, note: "custom — SF draws three FILLED stars; lucide Sparkles is outline + plus marks" },
  scope: { svg: customs.scope, note: "custom — lucide Crosshair's ticks stop at the ring" },
  scissors: { svg: customs.scissors, note: "custom — lucide Scissors is diagonal; SF lies horizontal" },
  "rectangle.split.2x1": { icon: Columns2 },
  "pencil.tip": { svg: customs.pencilTip, note: "custom nib — lucide PenTool reads as a fountain pen" },
  "mic.fill": { svg: customs.micFill, note: "custom — lucide Mic is outline-only" },
  "minus.magnifyingglass": { icon: ZoomOut },
  "plus.magnifyingglass": { icon: ZoomIn },
  "arrow.down.right.and.arrow.up.left": { svg: customs.arrowsInward, note: "custom — lucide Minimize2 uses the other diagonal" },

  // ── Inspector rail (InspectorTab.icon; selected tabs use `.fill`) ──
  paintpalette: { icon: Palette },
  "paintpalette.fill": { svg: customs.paletteFill, note: "custom — lucide has no filled palette" },
  cursorarrow: { svg: customs.cursorArrow, note: "custom — lucide MousePointer2 is tilted/tailless" },
  camera: { icon: Camera },
  "camera.fill": { icon: Camera, note: "no filled lucide camera — outline" },
  "speaker.wave.2": { icon: Volume2 },
  "speaker.wave.2.fill": { icon: Volume2 },
  "wand.and.stars": { icon: WandSparkles },
  "figure.walk.motion": { svg: customs.walkMotion, note: "custom — lucide has no walking figure" },
  "captions.bubble": { svg: customs.captionsBubble, note: "custom — lucide Captions is a rectangle" },
  "captions.bubble.fill": { svg: customs.captionsBubbleFill },
  "checkmark.seal": { icon: BadgeCheck },
  "checkmark.seal.fill": { icon: BadgeCheck },

  // ── Top bar / chrome ──
  "square.grid.2x2": { icon: LayoutGrid },
  "sidebar.right": { icon: PanelRight },
  "chevron.up.chevron.down": { icon: ChevronsUpDown },
  "chevron.left": { icon: ChevronLeft },
  "chevron.right": { icon: ChevronRight },
  "chevron.down": { icon: ChevronDown },
  checkmark: { icon: Check },
  plus: { icon: Plus },
  minus: { icon: Minus },
  photo: { icon: Image },
  "square.and.arrow.up": { icon: Share },
  icloud: { icon: Cloud },
  "icloud.and.arrow.up": { icon: CloudUpload },
  "checkmark.icloud": { icon: CloudCheck },
  "exclamationmark.icloud": { icon: CloudAlert },
  "icloud.slash": { icon: CloudOff },
  "arrow.triangle.2.circlepath": { icon: Loader },
  "arrow.clockwise": { icon: RefreshCw },
  link: { icon: Link },
  macwindow: { icon: AppWindow },
  display: { icon: Monitor },
  "sun.max": { icon: Sun },
  moon: { icon: Moon },
  "circle.lefthalf.filled": { icon: SunMoon },
  keyboard: { icon: Keyboard },
  "square.stack.3d.up": { icon: Layers },

  // ── Timeline lane glyphs ──
  "gauge.with.needle": { svg: customs.gauge, note: "custom — lucide Gauge is a half dial" },
  "rotate.3d": { icon: Rotate3d },
  "arrow.up.to.line": { icon: ArrowUpToLine },
  "book.pages": { icon: BookOpen },
  "waveform.and.mic": { icon: AudioLines },
  "speaker.slash.fill": { icon: VolumeX },
  "text.bubble": { icon: MessageSquareText },
  "arrow.up.right": { icon: ArrowUpRight },
  "pencil.and.scribble": { icon: PenLine },
  rectangle: { icon: RectangleHorizontal },
  oval: { icon: Circle, note: "lucide has no ellipse — circle" },
  "hand.tap": { icon: Hand },
  "pen.tool": { icon: PenTool },
  "person.standing": { icon: PersonStanding },
  "mouse.pointer": { icon: MousePointer2 },

  // ── Inspector panes (AudioVolumeRow / Annotate header / Brand) ──
  "speaker.slash": { icon: VolumeX },
  mic: { icon: Mic },
  "mic.slash": { icon: MicOff },
  textformat: { icon: CaseSensitive, note: "SF textformat is the \"Aa\" glyph" },
  "bubble.left": { icon: MessageSquare },
  scribble: { svg: customs.scribble, note: "custom — SF scribble is one looping stroke" },
  circle: { icon: Circle },
  "photo.badge.plus": { icon: ImagePlus },
  "seal.fill": { icon: Badge, fill: true, note: "lucide Badge is the scalloped seal outline — filled" },
  "hand.point.up.left": { icon: Pointer },
  // Annotation pill (AnnotationToolbarPill): background / fill on-off chip.
  "square.fill.on.square": { svg: customs.squareFillOnSquare, note: "custom — lucide has no filled square over an outlined one" },

  // ── Toolbar picker popovers (showZoomMenu / showFocusMenu) ──
  "sparkle.magnifyingglass": { icon: ScanSearch },
  "sparkles.rectangle.stack": { icon: GalleryVerticalEnd },
  "person.crop.rectangle": { icon: SquareUser },
  "person.crop.rectangle.badge.xmark": { icon: UserX },
  "eye.slash": { icon: EyeOff },
  "squareshape.split.3x3": { icon: Grid3x3 },
  highlighter: { icon: Highlighter },
  "camera.aperture": { icon: Aperture },
};

const strokeFor: Record<SFWeight, number> = { regular: 1.75, medium: 2, semibold: 2.3, bold: 2.6 };

type IconNode = [string, Record<string, string | number>][];

/** Lucide icons are forwardRef components whose render returns
 *  `<Icon iconNode={…}>` — calling it yields the node list, no mounting. */
function lucideNodes(icon: LucideIcon): IconNode | null {
  try {
    const render = (icon as unknown as { render?: (p: object, r: null) => { props: { iconNode?: IconNode } } }).render;
    return render?.({}, null)?.props?.iconNode ?? null;
  } catch {
    return null;
  }
}

const esc = (v: string | number) => String(v).replace(/"/g, "&quot;");

/** Full SVG markup for a symbol, drawn in `color` (black for masks). */
export function glyphSvgMarkup(name: string, px: number, color = "#000", weight: SFWeight = "semibold"): string | null {
  const entry = SF_SYMBOLS[name] ?? SF_SYMBOLS[name.replace(/\.fill$/, "")];
  if (!entry) return null;
  const sw = strokeFor[weight];
  let body: string;
  if (entry.svg) {
    body = entry.svg(sw);
  } else {
    const nodes = entry.icon ? lucideNodes(entry.icon) : null;
    if (!nodes) return null;
    const children = nodes
      .map(([tag, attrs]) => `<${tag} ${Object.entries(attrs).filter(([k]) => k !== "key").map(([k, v]) => `${k}="${esc(v)}"`).join(" ")}/>`)
      .join("");
    body = `<g fill="${entry.fill ? "#000" : "none"}" stroke="#000" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round">${children}</g>`;
  }
  if (color !== "#000") body = body.replace(/#000\b/g, color);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="0 0 24 24">${body}</svg>`;
}

const maskCache = new Map<string, string>();
function maskUrl(name: string, weight: SFWeight): string | null {
  const key = `${name}|${weight}`;
  let url = maskCache.get(key);
  if (url === undefined) {
    const markup = glyphSvgMarkup(name, 24, "#000", weight);
    url = markup ? `url("data:image/svg+xml;charset=utf-8,${encodeURIComponent(markup)}")` : "";
    maskCache.set(key, url);
  }
  return url || null;
}

export function SFIcon({
  name,
  size = 14,
  weight = "semibold",
  className,
  style,
}: {
  /** SF Symbol name as spelled in Swift. */
  name: string;
  /** SF pointSize. */
  size?: number;
  weight?: SFWeight;
  className?: string;
  style?: CSSProperties;
}) {
  const entry = SF_SYMBOLS[name] ?? SF_SYMBOLS[name.replace(/\.fill$/, "")];
  const box = Math.round(size * 1.2 * (entry?.scale ?? 1));
  const mask = maskUrl(name, weight);
  return (
    <span
      className={className}
      aria-hidden
      style={{
        display: "inline-block",
        flex: "none",
        width: box,
        height: box,
        backgroundColor: mask ? "currentColor" : undefined,
        WebkitMaskImage: mask ?? undefined,
        maskImage: mask ?? undefined,
        WebkitMaskSize: "100% 100%",
        maskSize: "100% 100%",
        WebkitMaskRepeat: "no-repeat",
        maskRepeat: "no-repeat",
        ...style,
      }}
    />
  );
}

/**
 * Canvas glyphs for the timeline: the same markup, rasterised once per
 * (name, size, colour, dpr) into a device-pixel canvas and cached. Returns
 * null while the SVG decodes (the caller redraws on `onReady`).
 */
const canvasGlyphCache = new Map<string, HTMLCanvasElement>();

export function canvasGlyph(
  name: string,
  cssPx: number,
  color: string,
  dpr: number,
  onReady: () => void,
  weight: SFWeight = "semibold",
): HTMLCanvasElement | null {
  const key = `${name}|${cssPx}|${color}|${dpr}|${weight}`;
  const hit = canvasGlyphCache.get(key);
  if (hit) return hit.width > 0 ? hit : null;
  const devPx = Math.max(1, Math.round(cssPx * dpr));
  const markup = glyphSvgMarkup(name, devPx, "#000", weight);
  const canvas = document.createElement("canvas");
  canvas.width = 0;
  canvasGlyphCache.set(key, canvas);
  if (!markup) return null;
  const img = new window.Image();
  img.onload = () => {
    canvas.width = devPx;
    canvas.height = devPx;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    // Template tint: draw the black glyph, then fill the colour INTO it once.
    ctx.drawImage(img, 0, 0, devPx, devPx);
    ctx.globalCompositeOperation = "source-in";
    ctx.fillStyle = color;
    ctx.fillRect(0, 0, devPx, devPx);
    onReady();
  };
  img.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(markup)}`;
  return null;
}
