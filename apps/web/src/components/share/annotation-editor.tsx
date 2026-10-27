import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";

import {
  ANNOTATION_LIMITS,
  canonicalShape,
  labelMetrics,
  luminance,
  serializeAnnotation,
  toBox,
  toFrame,
  type AnnotationShape,
  type Point,
  type Rect,
  type ShapeKind,
  type ShapeSize,
} from "@/lib/share/annotation";
import { formatTime } from "@/lib/share/comments";
import { AnnotationLayer, type MediaSize } from "./annotation-layer";

/* ------------------------------------------------------------------------ */
/* State                                                                    */
/* ------------------------------------------------------------------------ */

export type Tool = ShapeKind;

interface EditorState {
  open: boolean;
  tool: Tool;
  color: string;
  size: ShapeSize;
  shapes: AnnotationShape[];
  past: AnnotationShape[][];
  future: AnnotationShape[][];
  /** The shape under the pointer right now (not yet committed). */
  draft: AnnotationShape | null;
  /** An open text label input. */
  text: { at: Point; value: string } | null;
  /** Shapes when the editor opened — Esc restores them. */
  initial: AnnotationShape[];
}

type Action =
  | { type: "open"; shapes: AnnotationShape[]; color: string }
  | { type: "close" }
  | { type: "tool"; tool: Tool }
  | { type: "color"; color: string }
  | { type: "size"; size: ShapeSize }
  | { type: "draft"; shape: AnnotationShape | null }
  | { type: "commit"; shape: AnnotationShape }
  | { type: "undo" }
  | { type: "redo" }
  | { type: "clear" }
  | { type: "text-open"; at: Point }
  | { type: "text-value"; value: string }
  | { type: "text-close" };

const HISTORY_LIMIT = 100;

function withHistory(state: EditorState, shapes: AnnotationShape[]): EditorState {
  return {
    ...state,
    shapes,
    past: [...state.past, state.shapes].slice(-HISTORY_LIMIT),
    future: [],
  };
}

function reducer(state: EditorState, action: Action): EditorState {
  switch (action.type) {
    case "open":
      return {
        ...state,
        open: true,
        shapes: action.shapes,
        initial: action.shapes,
        past: [],
        future: [],
        draft: null,
        text: null,
        color: state.color || action.color,
      };
    case "close":
      return { ...state, open: false, draft: null, text: null, past: [], future: [] };
    case "tool":
      return { ...state, tool: action.tool };
    case "color":
      return { ...state, color: action.color };
    case "size":
      return { ...state, size: action.size };
    case "draft":
      return { ...state, draft: action.shape };
    case "commit":
      if (state.shapes.length >= ANNOTATION_LIMITS.maxShapes) return { ...state, draft: null };
      return { ...withHistory(state, [...state.shapes, action.shape]), draft: null };
    case "undo": {
      if (state.past.length === 0) return state;
      const previous = state.past[state.past.length - 1];
      return {
        ...state,
        shapes: previous,
        past: state.past.slice(0, -1),
        future: [state.shapes, ...state.future],
      };
    }
    case "redo": {
      if (state.future.length === 0) return state;
      const [next, ...rest] = state.future;
      return { ...state, shapes: next, past: [...state.past, state.shapes], future: rest };
    }
    case "clear":
      return state.shapes.length === 0 ? state : withHistory(state, []);
    case "text-open":
      return { ...state, text: { at: action.at, value: "" } };
    case "text-value":
      return state.text ? { ...state, text: { ...state.text, value: action.value } } : state;
    case "text-close":
      return { ...state, text: null };
  }
}

export interface AnnotationEditor {
  state: EditorState;
  open(shapes: AnnotationShape[]): void;
  close(): void;
  setTool(tool: Tool): void;
  setColor(color: string): void;
  setSize(size: ShapeSize): void;
  setDraft(shape: AnnotationShape | null): void;
  commit(shape: AnnotationShape): void;
  undo(): void;
  redo(): void;
  clear(): void;
  openText(at: Point): void;
  setTextValue(value: string): void;
  /** Commit the open label (if it has text) and close the input. */
  commitText(): void;
  cancelText(): void;
  /** Finish: commits any open label and returns the final shapes. */
  finish(): AnnotationShape[];
}

/**
 * Drawing state for one composer: tool/colour/size, the shape list with
 * undo/redo history, the in-flight shape and the label input.
 */
export function useAnnotationEditor(defaultColor: string): AnnotationEditor {
  const [state, dispatch] = useReducer(reducer, {
    open: false,
    tool: "pen",
    color: defaultColor,
    size: 2,
    shapes: [],
    past: [],
    future: [],
    draft: null,
    text: null,
    initial: [],
  } satisfies EditorState);
  const stateRef = useRef(state);
  stateRef.current = state;

  const labelShape = useCallback((): AnnotationShape | null => {
    const s = stateRef.current;
    if (!s.text) return null;
    return canonicalShape({ kind: "text", color: s.color, size: s.size, at: s.text.at, text: s.text.value });
  }, []);

  return useMemo<AnnotationEditor>(
    () => ({
      state,
      open: (shapes) => dispatch({ type: "open", shapes, color: defaultColor }),
      close: () => dispatch({ type: "close" }),
      setTool: (tool) => dispatch({ type: "tool", tool }),
      setColor: (color) => dispatch({ type: "color", color }),
      setSize: (size) => dispatch({ type: "size", size }),
      setDraft: (shape) => dispatch({ type: "draft", shape }),
      commit: (shape) => {
        // Committed shapes are stored canonical, so the composer shows
        // exactly what will be posted and what viewers will see.
        const canonical = canonicalShape(shape);
        if (canonical) dispatch({ type: "commit", shape: canonical });
        else dispatch({ type: "draft", shape: null });
      },
      undo: () => dispatch({ type: "undo" }),
      redo: () => dispatch({ type: "redo" }),
      clear: () => dispatch({ type: "clear" }),
      openText: (at) => dispatch({ type: "text-open", at }),
      setTextValue: (value) => dispatch({ type: "text-value", value }),
      // Idempotent within one tick: a pointer-down on the frame commits the
      // label AND blurs its input, and both must not add it twice.
      commitText: () => {
        const shape = labelShape();
        if (shape) dispatch({ type: "commit", shape });
        dispatch({ type: "text-close" });
        stateRef.current = { ...stateRef.current, text: null };
      },
      cancelText: () => {
        dispatch({ type: "text-close" });
        stateRef.current = { ...stateRef.current, text: null };
      },
      finish: () => {
        const shape = labelShape();
        const shapes = shape ? [...stateRef.current.shapes, shape] : stateRef.current.shapes;
        dispatch({ type: "close" });
        stateRef.current = { ...stateRef.current, text: null, open: false };
        return shapes;
      },
    }),
    [state, defaultColor, labelShape]
  );
}

/* ------------------------------------------------------------------------ */
/* Keyboard                                                                 */
/* ------------------------------------------------------------------------ */

export function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  if (target.isContentEditable) return true;
  const tag = target.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
}

const TOOL_KEYS: Record<string, Tool> = {
  d: "pen",
  a: "arrow",
  r: "rect",
  o: "ellipse",
  h: "highlight",
  t: "text",
};

/** Editor shortcuts while drawing. Typing in any field is left alone. */
export function useEditorShortcuts(
  editor: AnnotationEditor,
  { onDone, onCancel }: { onDone: () => void; onCancel: () => void }
) {
  const open = editor.state.open;
  const ref = useRef({ editor, onDone, onCancel });
  ref.current = { editor, onDone, onCancel };
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (isEditableTarget(e.target)) return;
      const { editor: ed, onDone: done, onCancel: cancel } = ref.current;
      const key = e.key.toLowerCase();
      const mod = e.metaKey || e.ctrlKey;
      // A focused button keeps its own Enter/Space (keyboard users pressing
      // Cancel must not get Done).
      if ((key === "enter" || key === " ") && e.target instanceof HTMLButtonElement) return;
      let handled = true;
      if (mod && key === "z") {
        if (e.shiftKey) ed.redo();
        else ed.undo();
      } else if (mod && key === "y") {
        ed.redo();
      } else if (mod || e.altKey) {
        handled = false;
      } else if (TOOL_KEYS[key]) {
        ed.setTool(TOOL_KEYS[key]);
      } else if (key === "1" || key === "2" || key === "3") {
        ed.setSize(Number(key) as ShapeSize);
      } else if (key === "escape") {
        cancel();
      } else if (key === "enter") {
        done();
      } else if (key === "backspace" || key === "delete") {
        // Delete the last-placed shape (undoable).
        ed.undo();
      } else if (key === " ") {
        // Space would toggle playback underneath the drawing.
      } else {
        handled = false;
      }
      if (handled) {
        e.preventDefault();
        e.stopPropagation();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [open]);
}

/* ------------------------------------------------------------------------ */
/* Drawing surface (over the video)                                         */
/* ------------------------------------------------------------------------ */

/** Snap a two-point shape when Shift is held: square/circle, or 45° arrow. */
function constrain(kind: Tool, from: Point, to: Point, rect: Rect): Point {
  const [fx, fy] = toBox(from, rect);
  let [tx, ty] = toBox(to, rect);
  const dx = tx - fx;
  const dy = ty - fy;
  if (kind === "rect" || kind === "ellipse") {
    const side = Math.max(Math.abs(dx), Math.abs(dy));
    tx = fx + Math.sign(dx || 1) * side;
    ty = fy + Math.sign(dy || 1) * side;
  } else if (kind === "arrow") {
    const len = Math.hypot(dx, dy);
    const angle = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
    tx = fx + Math.cos(angle) * len;
    ty = fy + Math.sin(angle) * len;
  }
  return toFrame(tx, ty, rect);
}

export function AnnotationSurface({
  editor,
  media,
  accent,
  time,
}: {
  editor: AnnotationEditor;
  media: MediaSize | null;
  accent: string;
  time: number;
}) {
  const { state } = editor;
  const surfaceRef = useRef<HTMLDivElement>(null);
  const rectRef = useRef<Rect>({ x: 0, y: 0, w: 0, h: 0 });
  const [rect, setRect] = useState<Rect>(rectRef.current);
  const activeRef = useRef<{ pointerId: number; shape: AnnotationShape } | null>(null);
  const textRef = useRef<HTMLInputElement>(null);
  const onFrameRect = useCallback((next: Rect) => {
    rectRef.current = next;
    setRect((prev) =>
      prev.x === next.x && prev.y === next.y && prev.w === next.w && prev.h === next.h ? prev : next
    );
  }, []);

  // Keyboard focus lands on the surface (not the composer textarea), so the
  // tool shortcuts work straight away.
  useEffect(() => {
    surfaceRef.current?.focus({ preventScroll: true });
  }, []);

  useEffect(() => {
    if (state.text) textRef.current?.focus({ preventScroll: true });
  }, [state.text?.at]); // eslint-disable-line react-hooks/exhaustive-deps

  const pointAt = (e: { clientX: number; clientY: number }): Point => {
    const el = surfaceRef.current;
    if (!el) return [0, 0];
    const b = el.getBoundingClientRect();
    return toFrame(e.clientX - b.left, e.clientY - b.top, rectRef.current);
  };

  const onPointerDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (e.pointerType === "mouse" && e.button !== 0) return;
    if (activeRef.current) return; // second finger: ignore
    e.preventDefault();
    const p = pointAt(e);
    if (state.text) editor.commitText();
    if (state.tool === "text") {
      editor.openText(p);
      return;
    }
    e.currentTarget.setPointerCapture(e.pointerId);
    const base = { color: state.color, size: state.size };
    const shape: AnnotationShape =
      state.tool === "pen" || state.tool === "highlight"
        ? { kind: state.tool, ...base, points: [p] }
        : { kind: state.tool as "arrow" | "rect" | "ellipse", ...base, from: p, to: p };
    activeRef.current = { pointerId: e.pointerId, shape };
    editor.setDraft(shape);
  };

  const onPointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    const active = activeRef.current;
    if (!active || active.pointerId !== e.pointerId) return;
    const rect = rectRef.current;
    const current = active.shape;
    let shape: AnnotationShape = current;
    if (current.kind === "pen" || current.kind === "highlight") {
      // Coalesced events keep fast strokes smooth on 120 Hz pointers.
      const native = e.nativeEvent as PointerEvent;
      const samples = typeof native.getCoalescedEvents === "function" ? native.getCoalescedEvents() : [];
      const points = current.points.slice();
      const minStep = rect.w > 0 ? 0.8 / rect.w : 0; // ~0.8 px
      for (const sample of samples.length > 0 ? samples : [native]) {
        const p = pointAt(sample);
        const last = points[points.length - 1];
        if (Math.hypot(p[0] - last[0], p[1] - last[1]) >= minStep) points.push(p);
      }
      shape = { ...current, points };
    } else if (current.kind === "arrow" || current.kind === "rect" || current.kind === "ellipse") {
      const raw = pointAt(e);
      shape = { ...current, to: e.shiftKey ? constrain(current.kind, current.from, raw, rect) : raw };
    }
    active.shape = shape;
    editor.setDraft(shape);
  };

  const finishPointer = (e: ReactPointerEvent<HTMLDivElement>) => {
    const active = activeRef.current;
    if (!active || active.pointerId !== e.pointerId) return;
    activeRef.current = null;
    if (e.currentTarget.hasPointerCapture(e.pointerId)) e.currentTarget.releasePointerCapture(e.pointerId);
    if (e.type === "pointercancel") editor.setDraft(null);
    else editor.commit(active.shape);
  };

  const shapes = useMemo(
    () => (state.draft ? [...state.shapes, state.draft] : state.shapes),
    [state.shapes, state.draft]
  );

  const label = state.text ? labelMetrics(state.size, rect) : null;
  const labelPos = state.text ? toBox(state.text.at, rect) : null;

  return (
    <div
      ref={surfaceRef}
      tabIndex={-1}
      role="application"
      aria-label="Drawing on the video frame. Shortcuts: D pen, A arrow, R rectangle, O ellipse, H highlighter, T text, Command-Z undo, Escape cancel, Enter done."
      className="absolute inset-0 z-30 select-none outline-none"
      style={{ touchAction: "none", cursor: state.tool === "text" ? "text" : "crosshair" }}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={finishPointer}
      onPointerCancel={finishPointer}
      onContextMenu={(e) => e.preventDefault()}
    >
      {/* Dim the frame a touch so marks read as the foreground. */}
      <div aria-hidden className="pointer-events-none absolute inset-0 bg-black/15" />
      <AnnotationLayer shapes={shapes} media={media} onFrameRect={onFrameRect} className="absolute inset-0" />
      {/* Frame outline in the accent: "you are drawing on THIS frame". */}
      <div
        aria-hidden
        className="pointer-events-none absolute rounded-[3px] motion-safe:animate-[cc-draw-in_220ms_ease-out]"
        style={{
          left: rect.x,
          top: rect.y,
          width: rect.w || "100%",
          height: rect.h || "100%",
          boxShadow: `inset 0 0 0 2px ${accent}`,
        }}
      />
      <span className="pointer-events-none absolute left-3 top-3 rounded-full bg-black/60 px-2.5 py-1 text-[11px] font-medium tabular-nums text-white/85 ring-1 ring-white/15 backdrop-blur-sm">
        Drawing at {formatTime(time)}
      </span>
      {state.text && label && labelPos && (
        <input
          ref={textRef}
          value={state.text.value}
          maxLength={ANNOTATION_LIMITS.maxTextLength}
          placeholder="Label"
          aria-label="Text label"
          onPointerDown={(e) => e.stopPropagation()}
          onChange={(e) => editor.setTextValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              editor.commitText();
              surfaceRef.current?.focus({ preventScroll: true });
            } else if (e.key === "Escape") {
              e.preventDefault();
              e.stopPropagation();
              editor.cancelText();
              surfaceRef.current?.focus({ preventScroll: true });
            }
          }}
          onBlur={() => editor.commitText()}
          className="absolute border-0 font-semibold outline-none placeholder:text-current placeholder:opacity-40"
          style={{
            left: labelPos[0],
            top: labelPos[1],
            font: label.font,
            lineHeight: `${label.lineHeight}px`,
            padding: `${label.padY}px ${label.padX}px`,
            borderRadius: label.radius,
            color: state.color,
            background: luminance(state.color) > 0.45 ? "rgba(10,11,16,0.72)" : "rgba(255,255,255,0.88)",
            boxShadow: `0 0 0 1.5px ${accent}`,
            width: `calc(${Math.max(5, [...state.text.value].length + 1)}ch + ${label.padX * 2}px)`,
            maxWidth: Math.max(80, rect.x + rect.w - labelPos[0]),
          }}
        />
      )}
      <style>{`
        @keyframes cc-draw-in { from { opacity: 0; } to { opacity: 1; } }
      `}</style>
    </div>
  );
}

/* ------------------------------------------------------------------------ */
/* Toolbar                                                                  */
/* ------------------------------------------------------------------------ */

const TOOLS: { tool: Tool; label: string; key: string; icon: ReactNode }[] = [
  { tool: "pen", label: "Pen", key: "D", icon: <PenIcon /> },
  { tool: "highlight", label: "Highlighter", key: "H", icon: <HighlighterIcon /> },
  { tool: "arrow", label: "Arrow", key: "A", icon: <ArrowIcon /> },
  { tool: "rect", label: "Rectangle", key: "R", icon: <RectIcon /> },
  { tool: "ellipse", label: "Ellipse", key: "O", icon: <EllipseIcon /> },
  { tool: "text", label: "Text", key: "T", icon: <TextIcon /> },
];

/** Swatches: the owner's accent first, then a small fixed set. */
export function annotationPalette(accent: string): string[] {
  const base = ["#ef4444", "#3b82f6", "#22c55e", "#ffffff", "#111111"];
  const a = accent.toLowerCase();
  return [a, ...base.filter((c) => c !== a)];
}

const groupClass =
  "flex items-center gap-0.5 rounded-full border border-white/10 bg-white/[0.04] p-[3px] backdrop-blur-sm";

function ToolButton({
  active,
  label,
  onClick,
  disabled,
  accent,
  children,
}: {
  active?: boolean;
  label: string;
  onClick: () => void;
  disabled?: boolean;
  accent: string;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      title={label}
      aria-label={label}
      aria-pressed={active}
      disabled={disabled}
      onClick={onClick}
      className={`grid h-[30px] w-[30px] place-items-center rounded-full text-white/75 transition-[background-color,transform,color] duration-150 hover:text-white motion-safe:active:scale-90 disabled:cursor-not-allowed disabled:opacity-35 ${
        active ? "bg-white/[0.16] text-white" : "hover:bg-white/[0.08]"
      }`}
      style={active ? { boxShadow: `0 0 0 1.5px ${accent}` } : undefined}
    >
      {children}
    </button>
  );
}

export function AnnotationToolbar({
  editor,
  accent,
  onDone,
  onCancel,
}: {
  editor: AnnotationEditor;
  accent: string;
  onDone: () => void;
  onCancel: () => void;
}) {
  const { state } = editor;
  const palette = useMemo(() => annotationPalette(accent), [accent]);
  const tooLarge = useMemo(() => serializeAnnotation(state.shapes).tooLarge, [state.shapes]);
  const atCap = state.shapes.length >= ANNOTATION_LIMITS.maxShapes;

  return (
    <div
      role="toolbar"
      aria-label="Drawing tools"
      // Pointer-downs here must not commit/blur the label input mid-click.
      onPointerDown={(e) => {
        if ((e.target as HTMLElement).closest("button")) e.preventDefault();
      }}
      className="flex flex-wrap items-center gap-1.5 px-1 pb-0.5 pt-2.5 motion-safe:animate-[cc-toolbar-in_200ms_cubic-bezier(0.2,0.9,0.3,1.2)]"
    >
      <div className={groupClass}>
        {TOOLS.map((t) => (
          <ToolButton
            key={t.tool}
            label={`${t.label} (${t.key})`}
            active={state.tool === t.tool}
            onClick={() => editor.setTool(t.tool)}
            accent={accent}
          >
            {t.icon}
          </ToolButton>
        ))}
      </div>

      <div className={groupClass} role="radiogroup" aria-label="Colour">
        {palette.map((color, i) => (
          <button
            key={color}
            type="button"
            role="radio"
            aria-checked={state.color === color}
            aria-label={i === 0 ? "Brand colour" : `Colour ${color}`}
            title={i === 0 ? "Brand colour" : color}
            onClick={() => editor.setColor(color)}
            className="grid h-[30px] w-[30px] place-items-center rounded-full transition-transform duration-150 motion-safe:hover:scale-110"
          >
            <span
              className="block h-[18px] w-[18px] rounded-full ring-1 ring-white/25"
              style={{
                backgroundColor: color,
                boxShadow: state.color === color ? `0 0 0 2px #0b0c11, 0 0 0 3.5px ${color === "#111111" ? "#ffffff" : color}` : undefined,
              }}
            />
          </button>
        ))}
      </div>

      <div className={groupClass} role="radiogroup" aria-label="Size">
        {([1, 2, 3] as ShapeSize[]).map((size) => (
          <button
            key={size}
            type="button"
            role="radio"
            aria-checked={state.size === size}
            aria-label={["Small", "Medium", "Large"][size - 1]}
            title={`${["Small", "Medium", "Large"][size - 1]} (${size})`}
            onClick={() => editor.setSize(size)}
            className={`grid h-[30px] w-[30px] place-items-center rounded-full transition-colors duration-150 ${
              state.size === size ? "bg-white/[0.16]" : "hover:bg-white/[0.08]"
            }`}
          >
            <span
              className="block rounded-full bg-white/85"
              style={{ width: 3 + size * 3, height: 3 + size * 3 }}
            />
          </button>
        ))}
      </div>

      <div className={groupClass}>
        <ToolButton label="Undo (⌘Z)" onClick={editor.undo} disabled={state.past.length === 0} accent={accent}>
          <UndoIcon />
        </ToolButton>
        <ToolButton label="Redo (⇧⌘Z)" onClick={editor.redo} disabled={state.future.length === 0} accent={accent}>
          <UndoIcon flip />
        </ToolButton>
        <ToolButton label="Clear all" onClick={editor.clear} disabled={state.shapes.length === 0} accent={accent}>
          <TrashIcon />
        </ToolButton>
      </div>

      <div className="ml-auto flex items-center gap-2">
        {(tooLarge || atCap) && (
          <span className="text-xs text-amber-300/90" role="status">
            {atCap ? "That's the most marks one comment holds" : "Too detailed — undo a few marks"}
          </span>
        )}
        <button
          type="button"
          onClick={onCancel}
          className="rounded-full border border-white/10 bg-white/[0.04] px-3.5 py-1.5 text-xs font-medium text-white/70 transition-colors hover:border-white/20 hover:bg-white/[0.1] hover:text-white"
        >
          Cancel <kbd className="ml-1 font-sans text-[10px] text-white/40">Esc</kbd>
        </button>
        <button
          type="button"
          onClick={onDone}
          disabled={tooLarge}
          className="rounded-full px-4 py-1.5 text-xs font-semibold text-black shadow-lg transition-transform duration-150 motion-safe:hover:scale-[1.03] motion-safe:active:scale-95 disabled:cursor-not-allowed disabled:opacity-50"
          style={{ backgroundColor: accent }}
        >
          Done
        </button>
      </div>
      <style>{`
        @keyframes cc-toolbar-in {
          from { opacity: 0; transform: translateY(-6px); }
          to { opacity: 1; transform: translateY(0); }
        }
      `}</style>
    </div>
  );
}

/* ------------------------------------------------------------------------ */
/* Icons                                                                    */
/* ------------------------------------------------------------------------ */

const iconProps = {
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.8,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
  className: "h-[18px] w-[18px]",
  "aria-hidden": true,
};

export function PenIcon({ className }: { className?: string }) {
  return (
    <svg {...iconProps} className={className ?? iconProps.className}>
      <path d="M4 20l1.2-4.4L15.6 5.2a2 2 0 0 1 2.8 0l.4.4a2 2 0 0 1 0 2.8L8.4 18.8 4 20z" />
      <path d="M13.5 7.3l3.2 3.2" />
    </svg>
  );
}

function HighlighterIcon() {
  return (
    <svg {...iconProps}>
      <path d="M9 15l-2.5 2.5L4 17l3.5-5.5" />
      <path d="M7.5 11.5l6-7a1.6 1.6 0 0 1 2.3-.1l3.8 3.8a1.6 1.6 0 0 1-.1 2.3l-7 6z" />
      <path d="M4 21h16" strokeOpacity="0.55" strokeWidth="3" />
    </svg>
  );
}

function ArrowIcon() {
  return (
    <svg {...iconProps}>
      <path d="M5 19L19 5" />
      <path d="M10 5h9v9" />
    </svg>
  );
}

function RectIcon() {
  return (
    <svg {...iconProps}>
      <rect x="4" y="6" width="16" height="12" rx="1.5" />
    </svg>
  );
}

function EllipseIcon() {
  return (
    <svg {...iconProps}>
      <ellipse cx="12" cy="12" rx="8.5" ry="6.5" />
    </svg>
  );
}

function TextIcon() {
  return (
    <svg {...iconProps}>
      <path d="M5 6.5V5h14v1.5M12 5v14M9 19h6" />
    </svg>
  );
}

function UndoIcon({ flip }: { flip?: boolean }) {
  return (
    <svg {...iconProps} style={flip ? { transform: "scaleX(-1)" } : undefined}>
      <path d="M9 14L4 9l5-5" />
      <path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11" />
    </svg>
  );
}

function TrashIcon() {
  return (
    <svg {...iconProps}>
      <path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3" />
    </svg>
  );
}
