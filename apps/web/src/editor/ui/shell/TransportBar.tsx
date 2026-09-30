/**
 * The timeline toolbar (TimelineViewController.buildToolbar), in the Mac's
 * exact order:
 *   ⏮ ▶ ⏭ │ 0:00 / 0:03 ……… ↶ ↷ │ 🗑 │ ✨ ⌖ ✂ ◫ ✎ │ 🎙 │ − ━━●━━ + ⤡
 * Every icon is its own raised key (no grouping pills). The timecode is
 * written straight to the DOM from the PlayheadChannel — React never
 * re-renders per frame.
 */
import { useEffect, useRef, useState, type MouseEvent } from "react";

import { GlideWash, IconKey, Popover, RailSlider, rectOf, SFIcon, ToolbarSeparator, useGlide, type AnchorRect } from "../kit";
import { formatTimecode } from "../timeline/snap";
import { M } from "../timeline/metrics";
import type {
  AnnotationPick,
  EditorShellCallbacks,
  EffectsPick,
  FocusPick,
  PlayheadChannel,
  ShellProjectInfo,
  TransportState,
} from "./types";

interface PickerRow<T extends string> {
  id: T;
  icon: string;
  title: string;
  detail: string;
  enabled?: boolean;
}

function effectsRows(project: ShellProjectInfo): PickerRow<EffectsPick>[] {
  return [
    ...(project.isImageCapture
      ? [{ id: "motion" as const, icon: "wand.and.stars", title: "Motion", detail: "Cinematic corner tour across the image" }]
      : []),
    { id: "autoZoom", icon: "sparkle.magnifyingglass", title: "Auto Zoom", detail: "Generate zooms from cursor movement", enabled: project.hasCursorData !== false },
    { id: "zoomIn", icon: "plus.magnifyingglass", title: "Zoom In", detail: "Push in at the playhead — drag the target to aim" },
    { id: "showcase", icon: "sparkles.rectangle.stack", title: "Showcase", detail: "Gentle zoom + 3D skew, returns to centre" },
    { id: "scaleDown", icon: "arrow.down.right.and.arrow.up.left", title: "Scale Down", detail: "Shrink the card for a beat, then back" },
    { id: "tilt", icon: "rotate.3d", title: "Tilt", detail: "Skew the screen in 3D for a span" },
    { id: "slide", icon: "arrow.up.to.line", title: "Slide", detail: "Card slides from an edge — place it anywhere" },
    { id: "curtain", icon: "book.pages", title: "Curtain Unveil", detail: "A curtain peels from a corner to reveal the screen" },
    { id: "cameraFull", icon: "person.crop.rectangle", title: "Camera: Full Screen", detail: "Webcam fills the card for a span — talking head", enabled: !!project.hasRecordedCamera },
    { id: "cameraSideBySide", icon: "rectangle.split.2x1", title: "Camera: Side by Side", detail: "Screen shrinks left, webcam fills the right", enabled: !!project.hasRecordedCamera },
    { id: "cameraHide", icon: "person.crop.rectangle.badge.xmark", title: "Camera: Hide", detail: "No webcam for a span — screen only", enabled: !!project.hasRecordedCamera },
  ];
}

const FOCUS_ROWS: PickerRow<FocusPick>[] = [
  { id: "blur", icon: "eye.slash", title: "Add Blur", detail: "Drag over an area to blur it" },
  { id: "pixelate", icon: "squareshape.split.3x3", title: "Add Pixelate", detail: "Drag over an area to pixelate it" },
  { id: "highlight", icon: "highlighter", title: "Add Highlight", detail: "Highlight a region of the video" },
  { id: "depthFocus", icon: "camera.aperture", title: "Add Depth Focus", detail: "Keep a region sharp, blur the rest" },
];

const ANNOTATION_ROWS: PickerRow<AnnotationPick>[] = [
  { id: "text", icon: "text.bubble", title: "Text Label", detail: "Add a text overlay" },
  { id: "arrow", icon: "arrow.up.right", title: "Arrow", detail: "Draw a directional arrow" },
  { id: "callout", icon: "pencil.tip", title: "Callout", detail: "Line with labelled box" },
  { id: "drawing", icon: "pencil.and.scribble", title: "Drawing", detail: "Freehand brush strokes" },
  { id: "rectangle", icon: "rectangle", title: "Rectangle", detail: "Box with optional fill" },
  { id: "ellipse", icon: "oval", title: "Ellipse", detail: "Circle / oval with optional fill" },
  { id: "tap", icon: "hand.tap", title: "Tap Indicator", detail: "Looping touch ripple for iPhone takes" },
];

/** TimelinePickerPopover: 28pt icon chip + bold title + detail, one glide wash. */
function PickerList<T extends string>({ rows, width, onPick }: { rows: PickerRow<T>[]; width: number; onPick: (id: T) => void }) {
  const glide = useGlide();
  const [hover, setHover] = useState<T | null>(null);
  return (
    <div
      ref={glide.containerRef}
      className="cc-picker-pop"
      style={{ width }}
      onPointerLeave={() => {
        setHover(null);
        glide.update(null);
      }}
    >
      <GlideWash glide={glide} />
      {rows.map((row) => (
        <button
          key={row.id}
          type="button"
          className="cc-pickrow"
          disabled={row.enabled === false}
          data-hover={hover === row.id || undefined}
          onPointerEnter={(e) => {
            if (row.enabled === false) return;
            setHover(row.id);
            glide.update(e.currentTarget);
          }}
          onClick={() => onPick(row.id)}
        >
          <span className="cc-pickrow__chip">
            <SFIcon name={row.icon} size={15} weight="semibold" />
          </span>
          <span className="cc-pickrow__text">
            <div className="cc-pickrow__title">{row.title}</div>
            <div className="cc-pickrow__detail" title={row.detail}>
              {row.detail}
            </div>
          </span>
        </button>
      ))}
    </div>
  );
}

type OpenPicker = { kind: "effects" | "focus" | "annotate"; anchor: AnchorRect; el: Element } | null;

export function TransportBar({
  project,
  transport,
  playhead,
  callbacks,
  scale,
  onScaleChange,
}: {
  project: ShellProjectInfo;
  transport: TransportState;
  playhead: PlayheadChannel;
  callbacks: EditorShellCallbacks;
  scale: number;
  onScaleChange: (scale: number) => void;
}) {
  const nowRef = useRef<HTMLSpanElement>(null);
  const [open, setOpen] = useState<OpenPicker>(null);

  // Live timecode — straight to the DOM.
  useEffect(() => {
    const write = (t: number) => {
      const el = nowRef.current;
      if (!el) return;
      const text = formatTimecode(t);
      if (el.textContent !== text) el.textContent = text;
    };
    write(playhead.get());
    return playhead.subscribe(write);
  }, [playhead]);

  const toggle = (kind: "effects" | "focus" | "annotate") => (e: MouseEvent<HTMLButtonElement>) => {
    const el = e.currentTarget;
    setOpen((o) => (o?.kind === kind ? null : { kind, anchor: rectOf(el), el }));
  };

  const timeless = !!transport.timelessTimeline;
  const log2 = Math.log2;

  return (
    <div className="cc-transport">
      <div className="cc-transport__group">
        <IconKey symbol="backward.end.fill" title="Go to Start" onClick={callbacks.onGoToStart} />
        <IconKey
          symbol={transport.isPlaying ? "pause.fill" : "play.fill"}
          pointSize={17}
          title={transport.isPlaying ? "Pause" : "Play"}
          onClick={callbacks.onTogglePlay}
        />
        <IconKey symbol="forward.end.fill" title="Go to End" onClick={callbacks.onGoToEnd} />
      </div>
      <ToolbarSeparator />
      <div className="cc-timecode" style={transport.hidesTime ? { visibility: "hidden" } : undefined}>
        <span ref={nowRef} className="cc-timecode__now">
          0:00
        </span>
        <span className="cc-timecode__div">/</span>
        <span className="cc-timecode__total">{formatTimecode(transport.duration)}</span>
      </div>
      <span className="cc-transport__spacer" />
      <IconKey symbol="arrow.uturn.backward" title="Undo" disabled={!transport.canUndo} onClick={callbacks.onUndo} />
      <IconKey symbol="arrow.uturn.forward" title="Redo" disabled={!transport.canRedo} onClick={callbacks.onRedo} />
      <ToolbarSeparator />
      <IconKey
        symbol="trash"
        title="Delete Selected"
        disabled={!transport.canDelete}
        tint={transport.canDelete ? "var(--cc-system-red)" : undefined}
        onClick={callbacks.onDelete}
      />
      <ToolbarSeparator />
      <IconKey symbol="sparkles" title="Zoom" active={open?.kind === "effects"} onClick={toggle("effects")} />
      <IconKey symbol="scope" title="Focus & Blur" active={open?.kind === "focus"} onClick={toggle("focus")} />
      <IconKey
        symbol="scissors"
        title={transport.sliceArmed ? "Exit Slice Tool" : "Slice clip — click to split"}
        active={transport.sliceArmed}
        tint={transport.sliceArmed ? "var(--cc-system-cyan)" : undefined}
        onClick={callbacks.onToggleSlice}
      />
      <IconKey symbol="rectangle.split.2x1" title="Split at Playhead (⌘B)" onClick={callbacks.onSplitAtPlayhead} />
      <IconKey symbol="pencil.tip" title="Add Annotation" active={open?.kind === "annotate"} onClick={toggle("annotate")} />
      <ToolbarSeparator />
      <IconKey
        symbol={transport.isRecordingVoiceOver ? "stop.fill" : "mic.fill"}
        title={transport.isRecordingVoiceOver ? "Stop Recording" : "Record Voice Over"}
        tint={transport.isRecordingVoiceOver ? "var(--cc-system-red)" : undefined}
        onClick={callbacks.onToggleVoiceOver}
      />
      <ToolbarSeparator />
      <IconKey
        symbol="minus.magnifyingglass"
        pointSize={12}
        title="Zoom Out Timeline"
        disabled={timeless || scale <= M.minScale}
        onClick={() => onScaleChange(scale / 1.5)}
      />
      <RailSlider
        width={72}
        min={log2(M.minScale)}
        max={log2(M.maxScale)}
        value={log2(scale)}
        disabled={timeless}
        ariaLabel="Timeline zoom"
        onChange={(v) => onScaleChange(2 ** v)}
      />
      <IconKey
        symbol="plus.magnifyingglass"
        pointSize={12}
        title="Zoom In Timeline"
        disabled={timeless || scale >= M.maxScale}
        onClick={() => onScaleChange(scale * 1.5)}
      />
      <IconKey
        symbol="arrow.down.right.and.arrow.up.left"
        pointSize={11}
        title="Fit Timeline"
        disabled={timeless || scale <= M.minScale}
        onClick={() => onScaleChange(1)}
      />

      {open && (
        <Popover anchor={open.anchor} edge="above" onDismiss={() => setOpen(null)} ignore={open.el}>
          {open.kind === "effects" && (
            <PickerList
              rows={effectsRows(project)}
              width={260}
              onPick={(id) => {
                setOpen(null);
                callbacks.onEffectsPick?.(id);
              }}
            />
          )}
          {open.kind === "focus" && (
            <PickerList
              rows={FOCUS_ROWS}
              width={240}
              onPick={(id) => {
                setOpen(null);
                callbacks.onFocusPick?.(id);
              }}
            />
          )}
          {open.kind === "annotate" && (
            <PickerList
              rows={ANNOTATION_ROWS}
              width={220}
              onPick={(id) => {
                setOpen(null);
                callbacks.onAnnotationPick?.(id);
              }}
            />
          )}
        </Popover>
      )}
    </div>
  );
}
