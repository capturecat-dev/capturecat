/**
 * PillSlider (CCSlider / InspectorSliderRow) and RailSlider
 * (InspectorSliderControl).
 *
 * PillSlider: a full-radius recessed pill carrying its own label, faint tick
 * marks and value; the thumb is a raised 4×18 bar (22 while dragging) that
 * tracks tight under the pointer and SETTLES on the house curve when the
 * value arrives from the model. Values read as 0–100% of the range unless a
 * human-unit `format` is given (%, ×, °, s) — px/pt never appear.
 */
import {
  useCallback,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type PointerEvent as ReactPointerEvent,
} from "react";

import { SFIcon } from "./icons";

const PILL_H_PADDING = 14;
const MAX_TICKS = 9;
const SPACE_LG = 16;
const SPACE_MD = 12;
const SPACE_XS = 4;

let measureCtx: CanvasRenderingContext2D | null = null;
function textWidth(text: string, font: string): number {
  if (typeof document === "undefined") return text.length * 6;
  measureCtx ??= document.createElement("canvas").getContext("2d");
  if (!measureCtx) return text.length * 6;
  measureCtx.font = font;
  return measureCtx.measureText(text).width;
}

const VALUE_FONT = `500 10.5px -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif`;

export function defaultPercent(value: number, min: number, max: number): string {
  const span = max - min;
  if (!(span > 0)) return "0%";
  const clamped = Math.min(Math.max(value, min), max);
  return `${Math.round(((clamped - min) / span) * 100)}%`;
}

function snap(value: number, min: number, max: number, step?: number) {
  let next = value;
  if (step && step > 0) next = Math.round((next - min) / step) * step + min;
  return Math.min(Math.max(next, min), max);
}

export interface PillSliderProps {
  title: string;
  value: number;
  min?: number;
  max?: number;
  step?: number;
  /** Human units only; nil = the house 0–100% readout. */
  format?: (value: number) => string;
  /** SF symbol after the title (e.g. a speaker). */
  symbol?: string;
  disabled?: boolean;
  onChange: (value: number) => void;
  /** Fires once on release (undo-batch boundary for the store). */
  onCommit?: (value: number) => void;
}

export function PillSlider({
  title,
  value,
  min = 0,
  max = 1,
  step,
  format,
  symbol,
  disabled,
  onChange,
  onCommit,
}: PillSliderProps) {
  const rootRef = useRef<HTMLDivElement>(null);
  const titleRef = useRef<HTMLSpanElement>(null);
  const [width, setWidth] = useState(0);
  const [titleWidth, setTitleWidth] = useState(0);
  const [hover, setHover] = useState(false);
  const [dragging, setDragging] = useState(false);
  const liveValue = useRef(value);
  liveValue.current = value;

  const display = useCallback(
    (v: number) => (format ? format(v) : defaultPercent(v, min, max)),
    [format, min, max],
  );

  useLayoutEffect(() => {
    const el = rootRef.current;
    if (!el) return;
    const measure = () => {
      setWidth(el.getBoundingClientRect().width);
      setTitleWidth(titleRef.current?.getBoundingClientRect().width ?? 0);
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    void document.fonts?.ready.then(measure);
    return () => ro.disconnect();
  }, [title, symbol]);

  const valueText = display(value);
  const reservedValueWidth = useMemo(
    () => Math.max(textWidth(display(min), VALUE_FONT), textWidth(display(max), VALUE_FONT)),
    [display, min, max],
  );

  // Travel runs between the label and the value — ticks and thumb never run
  // under the text (CCSlider.travel). Coordinates are in the OUTER box.
  const symbolWidth = symbol ? 16 + SPACE_XS : 0;
  const origin = PILL_H_PADDING + titleWidth + symbolWidth + SPACE_LG;
  const end = width - PILL_H_PADDING - Math.max(reservedValueWidth, textWidth(valueText, VALUE_FONT)) - SPACE_MD;
  const travel = Math.max(1, end - origin);
  const span = max - min;
  const fraction = span > 0 ? (Math.min(Math.max(value, min), max) - min) / span : 0;
  const visibleTicks = travel < 54 ? 0 : Math.min(MAX_TICKS, Math.floor(travel / 18));

  const commitAtX = (clientX: number) => {
    const el = rootRef.current;
    if (!el) return;
    const x = clientX - el.getBoundingClientRect().left;
    const f = Math.min(Math.max((x - origin) / travel, 0), 1);
    const next = snap(min + f * span, min, max, step);
    if (next !== liveValue.current) {
      liveValue.current = next;
      onChange(next);
    }
  };

  const onPointerDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (disabled || e.button !== 0) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    setDragging(true);
    commitAtX(e.clientX);
  };
  const onPointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (!dragging) return;
    commitAtX(e.clientX);
  };
  const endDrag = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (!dragging) return;
    commitAtX(e.clientX);
    setDragging(false);
    onCommit?.(liveValue.current);
  };

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    if (disabled) return;
    const unit = step && step > 0 ? step : span / 100;
    let next: number | null = null;
    if (e.key === "ArrowRight" || e.key === "ArrowUp") next = value + unit * (e.shiftKey ? 10 : 1);
    if (e.key === "ArrowLeft" || e.key === "ArrowDown") next = value - unit * (e.shiftKey ? 10 : 1);
    if (e.key === "Home") next = min;
    if (e.key === "End") next = max;
    if (next == null) return;
    e.preventDefault();
    next = snap(next, min, max, step);
    onChange(next);
    onCommit?.(next);
  };

  const thumbLeft = origin + (travel - 4) * fraction - 1; // −1: the border

  return (
    <div
      ref={rootRef}
      className="cc-pill-slider cc-mat-recessed cc-mat-pill"
      role="slider"
      tabIndex={disabled ? -1 : 0}
      aria-label={title}
      aria-valuemin={min}
      aria-valuemax={max}
      aria-valuenow={value}
      aria-valuetext={valueText}
      aria-disabled={disabled || undefined}
      data-hover={hover || dragging || undefined}
      data-dragging={dragging || undefined}
      onPointerEnter={() => !disabled && setHover(true)}
      onPointerLeave={() => setHover(false)}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={endDrag}
      onPointerCancel={endDrag}
      onKeyDown={onKeyDown}
    >
      <span className="cc-pill-slider__title">
        {/* Travel is measured from the title TEXT; the symbol's slot is the
            fixed 16 + xs CCSlider reserves (counting the glyph twice pushed
            the whole scale right on the Audio pane). */}
        <span ref={titleRef}>{title}</span>
        {symbol && <SFIcon name={symbol} size={11} weight="regular" style={{ color: "var(--cc-muted)" }} />}
      </span>
      {width > 0 &&
        Array.from({ length: visibleTicks }, (_, i) => (
          <span
            key={i}
            className="cc-pill-slider__tick"
            style={{ left: origin + travel * ((i + 1) / (visibleTicks + 1)) - 1 }}
          />
        ))}
      {width > 0 && <span className="cc-pill-slider__thumb" style={{ left: thumbLeft }} />}
      <span className="cc-pill-slider__value">{valueText}</span>
    </div>
  );
}

// ── RailSlider (InspectorSliderControl) ────────────────────────────────

/**
 * The bare custom track — a 3pt rail with an ink fill and a raised round
 * knob (12pt, 14 on hover/drag). Click anywhere to jump there, keep dragging.
 */
export function RailSlider({
  value,
  min = 0,
  max = 1,
  step,
  width = 72,
  disabled,
  ariaLabel,
  onChange,
}: {
  value: number;
  min?: number;
  max?: number;
  step?: number;
  width?: number;
  disabled?: boolean;
  ariaLabel?: string;
  onChange: (value: number) => void;
}) {
  const [dragging, setDragging] = useState(false);
  const [hover, setHover] = useState(false);
  const span = max - min;
  const fraction = span > 0 ? (Math.min(Math.max(value, min), max) - min) / span : 0;
  const knob = dragging || hover ? 14 : 12;
  const knobX = Math.max(1, width - knob) * fraction;

  const commit = (clientX: number, el: HTMLElement) => {
    const x = clientX - el.getBoundingClientRect().left;
    const usable = Math.max(1, width - 14);
    const f = Math.min(Math.max((x - 7) / usable, 0), 1);
    const next = snap(min + f * span, min, max, step);
    if (next !== value) onChange(next);
  };

  return (
    <div
      className="cc-rail-slider"
      role="slider"
      aria-label={ariaLabel}
      aria-valuemin={min}
      aria-valuemax={max}
      aria-valuenow={value}
      tabIndex={disabled ? -1 : 0}
      data-dragging={dragging || undefined}
      style={{ width, opacity: disabled ? 0.35 : undefined }}
      onPointerEnter={() => setHover(true)}
      onPointerLeave={() => setHover(false)}
      onPointerDown={(e) => {
        if (disabled || e.button !== 0) return;
        e.currentTarget.setPointerCapture(e.pointerId);
        setDragging(true);
        commit(e.clientX, e.currentTarget);
      }}
      onPointerMove={(e) => dragging && commit(e.clientX, e.currentTarget)}
      onPointerUp={(e) => {
        if (!dragging) return;
        commit(e.clientX, e.currentTarget);
        setDragging(false);
      }}
      onPointerCancel={() => setDragging(false)}
      onKeyDown={(e) => {
        const unit = step && step > 0 ? step : span / 20;
        if (e.key === "ArrowRight") onChange(snap(value + unit, min, max, step));
        if (e.key === "ArrowLeft") onChange(snap(value - unit, min, max, step));
      }}
    >
      <span className="cc-rail-slider__rail" />
      <span className="cc-rail-slider__fill" style={{ width: knobX + knob / 2 }} />
      <span className="cc-rail-slider__knob cc-mat-raised cc-mat-short" style={{ left: knobX }} />
    </div>
  );
}
