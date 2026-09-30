/**
 * Small pieces every pane shares: CodableColor ⇄ swatch colour, the
 * InspectorMenuControl row, Swift number formatting for slider readouts, and
 * the visible-only animation clock the live preview pads run on.
 */
import {
  useEffect,
  useMemo,
  useRef,
  type ComponentProps,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
  type RefObject,
} from "react";

import type { CodableColor } from "../../core/model";
import { formatFixed, sInt, srounded } from "../../core/math/swift";
import { InspectorButton, Row, Select, type RGBAColor } from "../kit";

// ── Colour ──────────────────────────────────────────────────────────────

export const toRGBA = (c: CodableColor): RGBAColor => ({ r: c.red, g: c.green, b: c.blue, a: c.opacity });

/** Swatch colour → CodableColor, keeping unknown keys of the value it replaces. */
export function toCodable(c: RGBAColor, previous?: CodableColor): CodableColor {
  const out: CodableColor = { red: c.r, green: c.g, blue: c.b, opacity: c.a };
  if (previous?.$extra) out.$extra = previous.$extra;
  return out;
}

export const WHITE: CodableColor = { red: 1, green: 1, blue: 1, opacity: 1 };

// ── Readouts (Swift String(format:) / Int() semantics) ──────────────────

/** `"\(Int((v * 100).rounded()))%"` */
export const pctRounded = (v: number) => `${sInt(srounded(v * 100))}%`;
/** `"\(Int(v * 100))%"` (truncating) */
export const pctTrunc = (v: number) => `${sInt(v * 100)}%`;
/** `String(format: "%.Nf<suffix>", v)` */
export const fixed = (digits: number, suffix = "") => (v: number) => `${formatFixed(v, digits)}${suffix}`;
/** `"\(Int(v.rounded()))°"` */
export const degRounded = (v: number) => `${sInt(srounded(v))}°`;
/** `"\(Int(v))°"` */
export const degTrunc = (v: number) => `${sInt(v)}°`;

/** `String(format: "%.2g", v)` for 1 ≤ v < 10 (two significant digits,
 *  trailing zeros dropped; exact binary ties round half-even like printf). */
export function sig2(v: number): string {
  if (!(v >= 1 && v < 10)) return String(+v.toPrecision(2));
  return formatFixed(v, 1).replace(/\.0$/, "");
}

// ── Buttons ─────────────────────────────────────────────────────────────

/** An InspectorButton added straight to a section (`addRow`) spans the pane
 *  width with its label at the leading edge — only buttons inside an
 *  NSStackView row keep their intrinsic width. */
export function RowButton(props: ComponentProps<typeof InspectorButton>) {
  return <InspectorButton {...props} style={{ alignSelf: "stretch", ...props.style }} />;
}

// ── Captions ────────────────────────────────────────────────────────────

/** InspectorKitViews.caption (wraps) / .captionLine (one truncating line,
 *  full text as the tooltip). */
export function Cap({ children, full, line }: { children: string; full?: string; line?: boolean }) {
  return (
    <div className="cc-caption" data-line={line || undefined} title={line ? (full ?? children) : undefined}>
      {children}
    </div>
  );
}

// ── Menu row (label left, flat drop-down right) ─────────────────────────

export function MenuRow({
  label,
  options,
  selectedIndex,
  onSelect,
  overrideTitle,
  trailing,
}: {
  label: string;
  options: readonly string[];
  selectedIndex: number;
  onSelect: (index: number) => void;
  overrideTitle?: string;
  /** Extra control after the menu (e.g. the "Test" sound button). */
  trailing?: ReactNode;
}) {
  const menu = (
    <Select
      chrome="flat"
      options={options.map((title) => ({ title }))}
      selectedIndex={Math.max(0, selectedIndex)}
      overrideTitle={overrideTitle}
      onSelect={onSelect}
      ariaLabel={label}
    />
  );
  return (
    <Row label={label}>
      {trailing ? (
        <span className="cc-pane-pair">
          {menu}
          {trailing}
        </span>
      ) : (
        menu
      )}
    </Row>
  );
}

// ── Visible-only animation clock ────────────────────────────────────────

/**
 * Runs `tick(nowSeconds)` on every animation frame while the element is on
 * screen (IntersectionObserver — a hidden pane or a scrolled-away pad costs
 * nothing), plus once on mount. Ticks write straight to the DOM; nothing
 * here re-renders React.
 */
export function useFrameLoop(ref: RefObject<HTMLElement | null>, tick: (now: number) => void) {
  const tickRef = useRef(tick);
  tickRef.current = tick;
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let raf = 0;
    let visible = false;
    const loop = (t: number) => {
      raf = 0;
      if (!visible) return;
      tickRef.current(t / 1000);
      raf = requestAnimationFrame(loop);
    };
    const io = new IntersectionObserver((entries) => {
      visible = entries.some((e) => e.isIntersecting);
      if (visible && !raf) raf = requestAnimationFrame(loop);
    });
    io.observe(el);
    tickRef.current(performance.now() / 1000);
    return () => {
      io.disconnect();
      if (raf) cancelAnimationFrame(raf);
    };
  }, [ref]);
}

/** Pointer drag: `onPoint` gets element-local coordinates on down + move,
 *  `onEnd` fires on release. Stable across re-renders mid-drag. */
export function useDrag(
  onPoint: (x: number, y: number, el: HTMLElement, e: ReactPointerEvent<HTMLElement>) => void,
  onEnd?: () => void,
) {
  const active = useRef(false);
  const cb = useRef({ onPoint, onEnd });
  cb.current = { onPoint, onEnd };
  return useMemo(() => {
    const local = (e: ReactPointerEvent<HTMLElement>) => {
      const r = e.currentTarget.getBoundingClientRect();
      cb.current.onPoint(e.clientX - r.left, e.clientY - r.top, e.currentTarget, e);
    };
    return {
      onPointerDown: (e: ReactPointerEvent<HTMLElement>) => {
        if (e.button !== 0) return;
        e.currentTarget.setPointerCapture(e.pointerId);
        active.current = true;
        local(e);
      },
      onPointerMove: (e: ReactPointerEvent<HTMLElement>) => {
        if (active.current) local(e);
      },
      onPointerUp: () => {
        if (!active.current) return;
        active.current = false;
        cb.current.onEnd?.();
      },
      onPointerCancel: () => {
        active.current = false;
      },
    };
  }, []);
}
