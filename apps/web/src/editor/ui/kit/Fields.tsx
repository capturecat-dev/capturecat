/**
 * ColorSwatch (InspectorColorWellControl + its picker popover), TextField
 * (CCField), inspector layout pieces (InspectorSectionBox, rows, captions)
 * and the recessed preview pad (CCPreviewPad).
 */
import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type HTMLAttributes,
  type InputHTMLAttributes,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";

import { rectOf, type AnchorRect } from "./Floating";
import { Popover } from "./Menu";
import { curves, cssCurve, durations, paceValue } from "./motion";

// ── Colour ──────────────────────────────────────────────────────────────

/** Normalised sRGB + opacity — the shape of Swift's CodableColor. */
export interface RGBAColor {
  r: number;
  g: number;
  b: number;
  a: number;
}

export const colorCss = (c: RGBAColor) =>
  `rgba(${Math.round(c.r * 255)}, ${Math.round(c.g * 255)}, ${Math.round(c.b * 255)}, ${+c.a.toFixed(3)})`;

export function colorToHex(c: RGBAColor): string {
  const h = (v: number) => Math.round(Math.min(1, Math.max(0, v)) * 255).toString(16).padStart(2, "0");
  return `#${h(c.r)}${h(c.g)}${h(c.b)}`.toUpperCase();
}

export function hexToColor(hex: string, a = 1): RGBAColor | null {
  const m = hex.trim().replace(/^#/, "");
  if (!/^[0-9a-f]{3}([0-9a-f]{3})?$/i.test(m)) return null;
  const full = m.length === 3 ? m.split("").map((ch) => ch + ch).join("") : m;
  const n = Number.parseInt(full, 16);
  return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255, a };
}

function toHsv({ r, g, b }: RGBAColor) {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const d = max - min;
  let h = 0;
  if (d > 0) {
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h *= 60;
    if (h < 0) h += 360;
  }
  return { h, s: max === 0 ? 0 : d / max, v: max };
}

function fromHsv(h: number, s: number, v: number, a: number): RGBAColor {
  const c = v * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = v - c;
  const [r, g, b] =
    h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
  return { r: r + m, g: g + m, b: b + m, a };
}

const PRESETS = [
  "#FFFFFF", "#000000", "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#007AFF", "#AF52DE",
  "#DD33EE", "#1A8CFF", "#5E5CE6", "#FF2D55", "#64D2FF", "#30D158", "#8E8E93", "#1C1C1E",
];

function useDrag(onPoint: (fx: number, fy: number) => void) {
  const dragging = useRef(false);
  const apply = (e: ReactPointerEvent<HTMLElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    onPoint(Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)), Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)));
  };
  return {
    onPointerDown: (e: ReactPointerEvent<HTMLElement>) => {
      e.currentTarget.setPointerCapture(e.pointerId);
      dragging.current = true;
      apply(e);
    },
    onPointerMove: (e: ReactPointerEvent<HTMLElement>) => dragging.current && apply(e),
    onPointerUp: () => {
      dragging.current = false;
    },
  };
}

export function ColorPicker({
  color,
  onChange,
  supportsOpacity = true,
}: {
  color: RGBAColor;
  onChange: (c: RGBAColor) => void;
  supportsOpacity?: boolean;
}) {
  // Hue is held locally so it survives passing through greys/black.
  const initial = toHsv(color);
  const [hsv, setHsv] = useState(initial);
  const [alpha, setAlpha] = useState(color.a);
  const [hex, setHex] = useState(colorToHex(color));

  const emit = (h: number, s: number, v: number, a: number) => {
    setHsv({ h, s, v });
    setAlpha(a);
    const next = fromHsv(h, s, v, a);
    setHex(colorToHex(next));
    onChange(next);
  };

  const sv = useDrag((fx, fy) => emit(hsv.h, fx, 1 - fy, alpha));
  const hue = useDrag((fx) => emit(fx * 359.999, hsv.s, hsv.v, alpha));
  const alphaDrag = useDrag((fx) => emit(hsv.h, hsv.s, hsv.v, fx));
  const opaque = colorCss({ ...fromHsv(hsv.h, hsv.s, hsv.v, 1) });

  return (
    <div className="cc-picker">
      <div className="cc-picker__sv" style={{ "--hue": hsv.h } as CSSProperties} {...sv}>
        <span className="cc-picker__handle" style={{ left: `${hsv.s * 100}%`, top: `${(1 - hsv.v) * 100}%`, background: opaque }} />
      </div>
      <div className="cc-picker__strip cc-picker__strip--hue" {...hue}>
        <span className="cc-picker__handle" style={{ left: `${(hsv.h / 360) * 100}%`, background: `hsl(${hsv.h} 100% 50%)` }} />
      </div>
      {supportsOpacity && (
        <div className="cc-picker__strip cc-picker__strip--alpha" style={{ "--opaque": opaque } as CSSProperties} {...alphaDrag}>
          <span className="cc-picker__handle" style={{ left: `${alpha * 100}%` }} />
        </div>
      )}
      <div className="cc-picker__row">
        <TextField
          size="sm"
          value={hex}
          aria-label="Hex colour"
          onChange={(e) => {
            setHex(e.target.value);
            const parsed = hexToColor(e.target.value, alpha);
            if (parsed) {
              const next = toHsv(parsed);
              setHsv(next);
              onChange(parsed);
            }
          }}
          style={{ fontVariantNumeric: "tabular-nums", textTransform: "uppercase" }}
        />
        {supportsOpacity && (
          <span className="cc-caption" style={{ minWidth: 34, textAlign: "right", fontVariantNumeric: "tabular-nums" }}>
            {Math.round(alpha * 100)}%
          </span>
        )}
      </div>
      <div className="cc-picker__presets">
        {PRESETS.map((p) => (
          <button
            key={p}
            type="button"
            className="cc-picker__preset"
            aria-label={p}
            style={{ background: p }}
            onClick={() => {
              const parsed = hexToColor(p, alpha)!;
              const next = toHsv(parsed);
              setHsv(next);
              setHex(p);
              onChange(parsed);
            }}
          />
        ))}
      </div>
    </div>
  );
}

/** 22pt round swatch (checkerboard under translucent colours) → picker popover. */
export function ColorSwatch({
  color,
  onChange,
  supportsOpacity = true,
  ariaLabel,
}: {
  color: RGBAColor;
  onChange: (c: RGBAColor) => void;
  supportsOpacity?: boolean;
  ariaLabel?: string;
}) {
  const ref = useRef<HTMLButtonElement>(null);
  const [anchor, setAnchor] = useState<AnchorRect | null>(null);
  return (
    <>
      <button
        ref={ref}
        type="button"
        className="cc-swatch"
        aria-label={ariaLabel ?? "Colour"}
        style={{ "--swatch": colorCss(color) } as CSSProperties}
        onPointerDown={(e) => {
          if (e.button !== 0) return;
          setAnchor((a) => (a ? null : rectOf(e.currentTarget)));
        }}
      />
      {anchor && (
        <Popover anchor={anchor} align="end" onDismiss={() => setAnchor(null)} ignore={ref.current}>
          <ColorPicker color={color} onChange={onChange} supportsOpacity={supportsOpacity} />
        </Popover>
      )}
    </>
  );
}

// ── TextField ───────────────────────────────────────────────────────────

/** CCField — recessed well; the ONLY control with a ring (ink, on focus). */
export function TextField({
  size = "regular",
  invalid,
  className,
  ...rest
}: Omit<InputHTMLAttributes<HTMLInputElement>, "size"> & { size?: "sm" | "regular"; invalid?: boolean }) {
  return (
    <input
      className={`cc-field cc-mat-recessed${className ? ` ${className}` : ""}`}
      data-size={size}
      aria-invalid={invalid || undefined}
      spellCheck={false}
      {...rest}
    />
  );
}

/**
 * InspectorFlatTextField — the inspector's pill field: elevated fill,
 * hairline border, 13pt, 14pt side padding, 33pt tall (text line + 8pt top
 * and bottom). Focus reads like a selected chip: the active wash plus the ink
 * outline (the one ring text inputs are allowed). Like the Mac field it
 * overhangs its layout slot by 2pt on each side (NSTextField alignment
 * inset), so a full-width field sits 2pt wider than a slider pill.
 *
 * `width` = the Mac `InspectorFlatTextField(width:)` — a compact paired
 * field ("Clock", "Start"); omit for full width.
 */
export function InspectorField({
  width,
  className,
  style,
  ...rest
}: InputHTMLAttributes<HTMLInputElement> & { width?: number }) {
  return (
    <input
      className={`cc-ifield${className ? ` ${className}` : ""}`}
      data-fixed={width != null || undefined}
      spellCheck={false}
      autoComplete="off"
      style={width != null ? { width: width + 4, ...style } : style}
      {...rest}
    />
  );
}

// ── Reveal (growth that bounces at the pushed edge) ─────────────────────

/**
 * A conditional inspector row (or section). Showing GROWS its slot — the gap
 * above it and its own height — from zero on the house bounce curve, so only
 * the pushed (bottom) edge overshoots and the rows above never move; the
 * content fades in with it. Hiding collapses on the settle curve and then
 * unmounts. The first render never animates, and a changed `marginTop` (the
 * stack spacing, e.g. when a neighbour hides) glides instead of jumping.
 */
export function Reveal({
  show,
  marginTop = 0,
  children,
}: {
  show: boolean;
  /** Final spacing above the row (the NSStackView spacing it sits at). */
  marginTop?: number;
  children: ReactNode;
}) {
  const [mounted, setMounted] = useState(show);
  const ref = useRef<HTMLDivElement>(null);
  const settled = useRef(false);
  const anim = useRef<Animation | null>(null);
  const kept = useRef<ReactNode>(children);
  if (show) kept.current = children;

  // Mount as soon as `show` flips on (the grow runs once the node exists).
  if (show && !mounted) setMounted(true);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!settled.current) {
      // First render: whatever state we start in is simply the state.
      settled.current = true;
      return;
    }
    if (!el) return;
    const reduced = typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    anim.current?.cancel();
    anim.current = null;
    if (show) {
      el.style.overflow = "";
      if (reduced) return;
      const h = el.scrollHeight;
      el.style.overflow = "hidden";
      const a = el.animate(
        [
          { height: "0px", marginTop: "0px", opacity: 0 },
          { height: `${h}px`, marginTop: `${marginTop}px`, opacity: 1 },
        ],
        { duration: (durations.grow / paceValue.standard) * 1000, easing: cssCurve(curves.bounce) },
      );
      anim.current = a;
      a.onfinish = () => {
        el.style.overflow = "";
        anim.current = null;
      };
    } else {
      if (reduced) {
        setMounted(false);
        return;
      }
      const h = el.getBoundingClientRect().height;
      el.style.overflow = "hidden";
      const a = el.animate(
        [
          { height: `${h}px`, marginTop: `${marginTop}px`, opacity: 1 },
          { height: "0px", marginTop: "0px", opacity: 0 },
        ],
        { duration: (durations.settle / paceValue.standard) * 1000, easing: cssCurve(curves.settle), fill: "forwards" },
      );
      anim.current = a;
      a.onfinish = () => {
        anim.current = null;
        setMounted(false);
      };
    }
    // Only a change of `show` starts a transition.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [show]);

  if (!mounted) return null;
  return (
    <div ref={ref} className="cc-grow" style={{ marginTop }}>
      {show ? children : kept.current}
    </div>
  );
}

// ── Inspector layout ────────────────────────────────────────────────────

/** Pane root: sections stacked 24pt apart. */
export function Pane({ children }: { children: ReactNode }) {
  return <div className="cc-pane">{children}</div>;
}

/**
 * InspectorSectionBox — uppercase tracked header, rows directly on the pane
 * (16pt rhythm), a full-width hairline above every section but the first.
 */
export function Section({
  title,
  children,
  first,
  hidden,
}: {
  title?: string;
  children: ReactNode;
  /** The first VISIBLE section drops its hairline (pass explicitly). */
  first?: boolean;
  hidden?: boolean;
}) {
  if (hidden) return null;
  return (
    <section className="cc-section" data-first={first || undefined}>
      <div className="cc-section__rule" />
      {title && <div className="cc-section__header">{title}</div>}
      <div className="cc-section__body">{children}</div>
    </section>
  );
}

/** A row glued tight (6pt) under the previous one — captions, pads. */
export function Attached({ children }: { children: ReactNode }) {
  return <div data-attached="true">{children}</div>;
}

/** Label left, any control right (InspectorKitViews.row). */
export function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="cc-row">
      <span className="cc-row__label">{label}</span>
      {children}
    </div>
  );
}

export function Caption({ children }: { children: ReactNode }) {
  return <div className="cc-caption">{children}</div>;
}

export function Divider() {
  return <div className="cc-divider" />;
}

/** CCPreviewPad — recessed demo well (placement / frame-style pads). */
export function PreviewPad({
  children,
  height = 96,
  style,
  ...rest
}: { children?: ReactNode; height?: number } & HTMLAttributes<HTMLDivElement>) {
  return (
    <div className="cc-pad cc-mat-recessed" style={{ height, ...style }} {...rest}>
      {children}
    </div>
  );
}

/** Keep a value in sync with a prop while letting local edits lead. */
export function useSyncedState<T>(value: T): [T, (v: T) => void] {
  const [local, setLocal] = useState(value);
  useEffect(() => setLocal(value), [value]);
  return [local, setLocal];
}
