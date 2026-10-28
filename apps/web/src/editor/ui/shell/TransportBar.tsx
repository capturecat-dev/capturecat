/**
 * The timeline toolbar (TimelineViewController.buildToolbar), in the Mac's
 * exact order:
 *   ⏮ ▶ ⏭ │ 0:00 / 0:03 ……… ↶ ↷ │ 🗑 │ ✨ ⌖ ✂ ◫ ✎ │ 🎙 │ − ━━●━━ + ⤡
 * Every icon is its own raised key (no grouping pills). The timecode is
 * written straight to the DOM from the PlayheadChannel — React never
 * re-renders per frame.
 */
import { useEffect, useRef, useState, type MouseEvent } from "react";

import { IconKey, MenuList, Popover, RailSlider, rectOf, SFIcon, ToolbarSeparator, type AnchorRect, type MenuEntry } from "../kit";
import { formatTimecode } from "../timeline/snap";
import { M } from "../timeline/metrics";
import type {
  AnnotationPick,
  CameraMaskChip,
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

interface PickerGroup<T extends string> {
  /** Sentence-case section header. */
  title?: string;
  /** Shown once under the header when the whole group is unavailable. */
  disabledCaption?: string;
  /** The group is unavailable (its rows dim; the caption says why). */
  disabled?: boolean;
  rows: PickerRow<T>[];
}

/**
 * The Effects picker (TimelinePickerPopover), grouped like the Mac's:
 * zoom & motion · transitions · camera. The camera looks need a recorded
 * camera — without one the group stays visible, dimmed, with one caption.
 */
function effectsGroups(project: ShellProjectInfo): PickerGroup<EffectsPick>[] {
  const camera = !!project.hasRecordedCamera;
  return [
    {
      title: "Zoom & motion",
      rows: [
        ...(project.isImageCapture
          ? [{ id: "motion" as const, icon: "wand.and.stars", title: "Motion", detail: "A cinematic corner tour across the image" }]
          : []),
        {
          id: "autoZoom",
          icon: "sparkle.magnifyingglass",
          title: "Auto Zoom",
          detail: project.hasCursorData === false ? "Needs cursor data from the recording" : "Generate zooms from cursor movement",
          enabled: project.hasCursorData !== false,
        },
        { id: "zoomIn", icon: "plus.magnifyingglass", title: "Zoom In", detail: "Push in at the playhead — drag the target to aim" },
        { id: "showcase", icon: "sparkles.rectangle.stack", title: "Showcase", detail: "A gentle zoom and 3D skew that returns to centre" },
        { id: "scaleDown", icon: "arrow.down.right.and.arrow.up.left", title: "Scale Down", detail: "Shrink the card for a beat, then back" },
        { id: "tilt", icon: "rotate.3d", title: "Tilt", detail: "Skew the screen in 3D for a span" },
      ],
    },
    {
      title: "Transitions",
      rows: [
        { id: "slide", icon: "arrow.up.to.line", title: "Slide", detail: "The card slides in from an edge — place it anywhere" },
        { id: "curtain", icon: "book.pages", title: "Curtain Unveil", detail: "A curtain peels from a corner to reveal the screen" },
      ],
    },
    {
      title: "Camera",
      disabled: !camera,
      disabledCaption: "Needs a camera recording",
      rows: [
        { id: "cameraFull", icon: "person.crop.rectangle", title: "Full Screen", detail: "The webcam fills the card — a talking head" },
        { id: "cameraSideBySide", icon: "rectangle.split.2x1", title: "Side by Side", detail: "The screen shrinks left; the webcam fills the right" },
        { id: "cameraCutout", icon: "person.and.background.dotted", title: "Cutout", detail: "The webcam with its background removed, over the screen" },
        { id: "cameraPopOut", icon: "person-popout", title: "Pop-out card", detail: "A cut-out webcam on a card — the head breaks out the top" },
        { id: "cameraHide", icon: "person.crop.rectangle.badge.xmark", title: "Hide Camera", detail: "No webcam for a span — the screen only" },
      ],
    },
  ];
}

/**
 * Background removal beside the Effects key (docs/camera-cutout.md §9): a
 * recessed well with a spinner, the progress line and a fill bar while the
 * camera is segmented (Cancel stops it); an error / notice reads in the same
 * well until dismissed.
 */
function CameraMaskChipView({ chip }: { chip: CameraMaskChip }) {
  const pct = chip.fraction != null ? Math.max(0, Math.min(1, chip.fraction)) : null;
  return (
    <span className={`cc-maskchip cc-mat-recessed cc-mat-pill cc-maskchip--${chip.tone}`} role="status" aria-live="polite" title={chip.text}>
      {chip.busy ? <span className="cc-spin cc-maskchip__spin" aria-hidden /> : <SFIcon name={chip.tone === "error" ? "exclamationmark.triangle" : "info.circle"} size={11} />}
      <span className="cc-maskchip__text">{chip.text}</span>
      {chip.busy && pct != null ? (
        <span className="cc-maskchip__bar" aria-hidden>
          <span className="cc-maskchip__fill" style={{ transform: `scaleX(${pct})` }} />
        </span>
      ) : null}
      {chip.busy && chip.onCancel ? (
        <button type="button" className="cc-maskchip__x" title="Cancel background removal" onClick={chip.onCancel}>
          <SFIcon name="xmark" size={9} weight="bold" />
        </button>
      ) : null}
      {!chip.busy && chip.onDismiss ? (
        <button type="button" className="cc-maskchip__x" title="Dismiss" onClick={chip.onDismiss}>
          <SFIcon name="xmark" size={9} weight="bold" />
        </button>
      ) : null}
    </span>
  );
}

const FOCUS_GROUPS: PickerGroup<FocusPick>[] = [
  {
    rows: [
      { id: "blur", icon: "eye.slash", title: "Add Blur", detail: "Drag over an area to blur it" },
      { id: "pixelate", icon: "squareshape.split.3x3", title: "Add Pixelate", detail: "Drag over an area to pixelate it" },
      { id: "highlight", icon: "highlighter", title: "Add Highlight", detail: "Highlight a region of the video" },
      { id: "depthFocus", icon: "camera.aperture", title: "Add Depth Focus", detail: "Keep a region sharp and blur the rest" },
    ],
  },
];

const ANNOTATION_GROUPS: PickerGroup<AnnotationPick>[] = [
  {
    rows: [
      { id: "text", icon: "text.bubble", title: "Text Label", detail: "Add a text overlay" },
      { id: "arrow", icon: "arrow.up.right", title: "Arrow", detail: "Draw a directional arrow" },
      { id: "callout", icon: "pencil.tip", title: "Callout", detail: "A line with a labelled box" },
      { id: "drawing", icon: "pencil.and.scribble", title: "Drawing", detail: "Freehand brush strokes" },
      { id: "rectangle", icon: "rectangle", title: "Rectangle", detail: "A box with an optional fill" },
      { id: "ellipse", icon: "oval", title: "Ellipse", detail: "A circle or oval with an optional fill" },
      { id: "tap", icon: "hand.tap", title: "Tap Indicator", detail: "A looping touch ripple for iPhone takes" },
    ],
  },
];

/** TimelinePickerPopover → the kit MenuList's rich rows (tile + title + description). */
function pickerEntries<T extends string>(groups: PickerGroup<T>[], onPick: (id: T) => void): MenuEntry[] {
  const entries: MenuEntry[] = [];
  for (const g of groups) {
    if (g.title) entries.push({ section: g.title, disabled: g.disabled, caption: g.disabled ? g.disabledCaption : undefined });
    for (const row of g.rows) {
      entries.push({
        title: row.title,
        description: row.detail,
        icon: row.icon,
        disabled: row.enabled === false,
        onSelect: () => onPick(row.id),
      });
    }
  }
  return entries;
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
      {project.cameraMask ? <CameraMaskChipView chip={project.cameraMask} /> : null}
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
            <MenuList
              ariaLabel="Add effect"
              entries={pickerEntries(effectsGroups(project), (id) => callbacks.onEffectsPick?.(id))}
              onClose={() => setOpen(null)}
            />
          )}
          {open.kind === "focus" && (
            <MenuList
              ariaLabel="Add focus or blur"
              entries={pickerEntries(FOCUS_GROUPS, (id) => callbacks.onFocusPick?.(id))}
              onClose={() => setOpen(null)}
            />
          )}
          {open.kind === "annotate" && (
            <MenuList
              ariaLabel="Add annotation"
              entries={pickerEntries(ANNOTATION_GROUPS, (id) => callbacks.onAnnotationPick?.(id))}
              onClose={() => setOpen(null)}
            />
          )}
        </Popover>
      )}
    </div>
  );
}
