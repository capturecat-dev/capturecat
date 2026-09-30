/**
 * Floating surfaces (menus, popovers) + the travelling glide highlight.
 *
 * Floating: fixed-position panel rendered into the ThemeRoot portal (so it
 * inherits tokens), anchored to a rect, flipped/clamped to stay on screen,
 * dismissed by outside press or Escape. Arrives with the house scaleIn
 * (spring smooth from 96%) + a glide fade — CCMotion.enter(.scaleIn).
 *
 * useGlide: CCGlideHighlight — ONE wash per sibling group that springs
 * between hovered rows (snappy), appears in place when faded out, and fades
 * where it stands on exit.
 */
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
  type RefObject,
} from "react";
import { createPortal } from "react-dom";

import { useCCTheme } from "./theme";

export type Edge = "below" | "above" | "right" | "left";

export interface AnchorRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export function rectOf(el: Element): AnchorRect {
  const r = el.getBoundingClientRect();
  return { left: r.left, top: r.top, width: r.width, height: r.height };
}

export function Floating({
  anchor,
  edge = "below",
  align = "start",
  gap = 5,
  minWidth,
  onDismiss,
  ignore,
  children,
  className,
  style,
  role,
}: {
  anchor: AnchorRect;
  edge?: Edge;
  align?: "start" | "center" | "end";
  gap?: number;
  minWidth?: number;
  onDismiss: () => void;
  /** Presses inside this element (the trigger) don't dismiss — the trigger toggles. */
  ignore?: Element | null;
  children: ReactNode;
  className?: string;
  style?: CSSProperties;
  role?: string;
}) {
  const { portal } = useCCTheme();
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number; origin: string; maxHeight?: number } | null>(null);
  const dismissRef = useRef(onDismiss);
  dismissRef.current = onDismiss;
  const ignoreRef = useRef(ignore);
  ignoreRef.current = ignore;

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const w = el.offsetWidth;
    const h = el.offsetHeight;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    let left = anchor.left;
    let top = anchor.top + anchor.height + gap;
    let origin = "top";
    let maxHeight: number | undefined;
    if (edge === "below" || edge === "above") {
      if (align === "center") left = anchor.left + anchor.width / 2 - w / 2;
      if (align === "end") left = anchor.left + anchor.width - w;
      const below = anchor.top + anchor.height + gap;
      const spaceAbove = anchor.top - gap - 8;
      const spaceBelow = vh - 8 - below;
      const wantAbove = edge === "above";
      // Preferred side if it fits; else the side that fits; else the roomier
      // side, height-capped and scrolling — never covering the trigger.
      const fitsAbove = h <= spaceAbove;
      const fitsBelow = h <= spaceBelow;
      const useAbove = wantAbove ? fitsAbove || (!fitsBelow && spaceAbove >= spaceBelow) : !fitsBelow && (fitsAbove || spaceAbove > spaceBelow);
      if (useAbove) {
        maxHeight = fitsAbove ? undefined : spaceAbove;
        top = anchor.top - gap - Math.min(h, spaceAbove);
        origin = "bottom";
      } else {
        maxHeight = fitsBelow ? undefined : spaceBelow;
        top = below;
        origin = "top";
      }
    } else {
      top = anchor.top;
      const right = anchor.left + anchor.width + gap;
      const leftSide = anchor.left - gap - w;
      left = edge === "right" ? (right + w > vw - 8 ? leftSide : right) : leftSide < 8 ? right : leftSide;
      origin = edge === "right" ? "left" : "right";
    }
    left = Math.min(Math.max(8, left), Math.max(8, vw - w - 8));
    if (maxHeight == null) top = Math.min(Math.max(8, top), Math.max(8, vh - h - 8));
    const ox = Math.min(Math.max(anchor.left + anchor.width / 2 - left, 0), w);
    setPos({
      left,
      top,
      maxHeight,
      origin: origin === "top" ? `${ox}px 0` : origin === "bottom" ? `${ox}px 100%` : origin === "left" ? "0 50%" : "100% 50%",
    });
  }, [anchor.left, anchor.top, anchor.width, anchor.height, edge, align, gap]);

  useEffect(() => {
    const onDown = (e: PointerEvent) => {
      const target = e.target as Node;
      if (ignoreRef.current?.contains(target)) return;
      if (ref.current && !ref.current.contains(target)) dismissRef.current();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        dismissRef.current();
      }
    };
    const onBlur = () => dismissRef.current();
    // Capture phase: the press that dismisses must not also activate what's under it twice.
    window.addEventListener("pointerdown", onDown, true);
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("blur", onBlur);
    return () => {
      window.removeEventListener("pointerdown", onDown, true);
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("blur", onBlur);
    };
  }, []);

  if (!portal) return null;
  return createPortal(
    <div
      ref={ref}
      role={role}
      className={`cc-float${className ? ` ${className}` : ""}`}
      style={{
        left: pos?.left ?? -9999,
        top: pos?.top ?? -9999,
        minWidth,
        maxHeight: pos?.maxHeight,
        overflowY: pos?.maxHeight != null ? "auto" : undefined,
        visibility: pos ? "visible" : "hidden",
        ["--float-origin" as string]: pos?.origin ?? "top center",
        ...style,
      }}
    >
      {children}
    </div>,
    portal,
  );
}

// ── Glide highlight ─────────────────────────────────────────────────────

export interface GlideController {
  /** Attach to the positioned container (the wash lives inside it). */
  containerRef: RefObject<HTMLDivElement | null>;
  /** The wash element's ref. */
  washRef: RefObject<HTMLSpanElement | null>;
  /** Report hover intent for a row element (null = pointer left the group). */
  update: (row: HTMLElement | null) => void;
}

export function useGlide(): GlideController {
  const containerRef = useRef<HTMLDivElement>(null);
  const washRef = useRef<HTMLSpanElement>(null);
  const visible = useRef(false);

  const update = useCallback((row: HTMLElement | null) => {
    const wash = washRef.current;
    const container = containerRef.current;
    if (!wash || !container) return;
    if (!row) {
      visible.current = false;
      wash.style.opacity = "0";
      return;
    }
    const c = container.getBoundingClientRect();
    const r = row.getBoundingClientRect();
    const x = r.left - c.left + container.scrollLeft;
    const y = r.top - c.top + container.scrollTop;
    // Faded out → jump in place, then fade in; visible → spring there.
    wash.dataset.instant = visible.current ? "false" : "true";
    wash.style.transform = `translate(${x}px, ${y}px)`;
    wash.style.width = `${r.width}px`;
    wash.style.height = `${r.height}px`;
    if (!visible.current) void wash.offsetWidth; // commit the jump before fading in
    wash.dataset.instant = "false";
    wash.style.opacity = "1";
    visible.current = true;
  }, []);

  return useMemo(() => ({ containerRef, washRef, update }), [update]);
}

/** The wash element for a glide group. */
export function GlideWash({ glide, radius }: { glide: GlideController; radius?: number }) {
  return (
    <span
      ref={glide.washRef}
      className="cc-glide"
      data-instant="true"
      style={radius != null ? { borderRadius: radius } : undefined}
      aria-hidden
    />
  );
}
