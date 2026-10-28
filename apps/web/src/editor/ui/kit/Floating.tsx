/**
 * Floating surfaces (menus, popovers) + the travelling glide highlight.
 *
 * Floating: fixed-position panel rendered into the ThemeRoot portal (so it
 * inherits tokens), anchored to a rect, flipped/clamped to stay on screen,
 * dismissed by outside press or Escape.
 *
 * Motion (the 2026 menu spec, shared with the Mac's CCMenu):
 *  • OPEN — a 120ms fade + scale .96→1 and a 6px slide away from the
 *    trigger, on the house bounce (a slight overshoot), growing from the
 *    side nearest the trigger (`data-side` + --float-dx/dy/origin).
 *  • CLOSE — the panel is unmounted by its owner as before; on the way out a
 *    static GHOST clone takes its place for ~100ms (fade + scale .98), so no
 *    call site needs a presence state. A ghost whose menu was picked from
 *    (`data-picked`) first pulses the chosen row's wash (~120ms).
 *  Reduced motion: fades only (no scale, slide or pulse).
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
  const [pos, setPos] = useState<{ left: number; top: number; origin: string; side: Edge; maxHeight?: number } | null>(null);
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
    let side: Edge = "below";
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
        side = "above";
      } else {
        maxHeight = fitsBelow ? undefined : spaceBelow;
        top = below;
        origin = "top";
        side = "below";
      }
    } else {
      top = anchor.top;
      const right = anchor.left + anchor.width + gap;
      const leftSide = anchor.left - gap - w;
      left = edge === "right" ? (right + w > vw - 8 ? leftSide : right) : leftSide < 8 ? right : leftSide;
      side = left >= anchor.left + anchor.width ? "right" : "left";
      origin = side === "right" ? "left" : "right";
    }
    left = Math.min(Math.max(8, left), Math.max(8, vw - w - 8));
    if (maxHeight == null) top = Math.min(Math.max(8, top), Math.max(8, vh - h - 8));
    const ox = Math.min(Math.max(anchor.left + anchor.width / 2 - left, 0), w);
    const oy = Math.min(Math.max(anchor.top + anchor.height / 2 - top, 0), h);
    setPos({
      left,
      top,
      maxHeight,
      side,
      origin: origin === "top" ? `${ox}px 0` : origin === "bottom" ? `${ox}px 100%` : origin === "left" ? `0 ${oy}px` : `100% ${oy}px`,
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

  // CLOSE: when the owner unmounts us, a static ghost fades out in our place.
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const parent = el.parentNode;
    return () => {
      // StrictMode's simulated unmount keeps the node connected — no ghost.
      queueMicrotask(() => {
        if (!el.isConnected && parent?.isConnected) leaveAsGhost(el, parent);
      });
    };
  }, [portal]);

  const slide = SLIDE[pos?.side ?? "below"];
  if (!portal) return null;
  return createPortal(
    <div
      ref={ref}
      role={role}
      className={`cc-float${className ? ` ${className}` : ""}`}
      data-side={pos?.side}
      style={{
        left: pos?.left ?? -9999,
        top: pos?.top ?? -9999,
        minWidth,
        maxHeight: pos?.maxHeight,
        overflowY: pos?.maxHeight != null ? "auto" : undefined,
        visibility: pos ? "visible" : "hidden",
        ["--float-origin" as string]: pos?.origin ?? "top center",
        ["--float-dx" as string]: `${slide[0]}px`,
        ["--float-dy" as string]: `${slide[1]}px`,
        ...style,
      }}
    >
      {children}
    </div>,
    portal,
  );
}

/** The 6px entrance slide, pointing AWAY from the trigger (it starts nearer it). */
const SLIDE: Record<Edge, [number, number]> = {
  below: [0, -6],
  above: [0, 6],
  right: [-6, 0],
  left: [6, 0],
};

const prefersReducedMotion = () =>
  typeof window !== "undefined" && !!window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

/**
 * Put an inert clone of a just-removed floating panel back where it was and
 * play the exit on it (cc-float-out / cc-float-pick-out in kit.css), then
 * drop it. Canvases are copied (cloneNode leaves them blank).
 */
function leaveAsGhost(el: HTMLElement, parent: Node) {
  if (typeof document === "undefined") return;
  const ghost = el.cloneNode(true) as HTMLElement;
  ghost.setAttribute("data-cc-ghost", "");
  ghost.setAttribute("aria-hidden", "true");
  ghost.removeAttribute("role");
  ghost.inert = true;
  ghost.classList.add("cc-float--leaving");
  const from = el.querySelectorAll("canvas");
  const to = ghost.querySelectorAll("canvas");
  from.forEach((c, i) => {
    try {
      const d = to[i];
      d.width = c.width;
      d.height = c.height;
      d.getContext("2d")?.drawImage(c, 0, 0);
    } catch {
      /* tainted / zero-size canvas — leave it blank */
    }
  });
  // Keep the scroll position the panel had.
  const scrollers = [el, ...el.querySelectorAll<HTMLElement>(".cc-menu")];
  const ghostScrollers = [ghost, ...ghost.querySelectorAll<HTMLElement>(".cc-menu")];
  parent.appendChild(ghost);
  scrollers.forEach((s, i) => {
    if (s.scrollTop && ghostScrollers[i]) ghostScrollers[i].scrollTop = s.scrollTop;
  });
  let done = false;
  const remove = () => {
    if (done) return;
    done = true;
    ghost.remove();
  };
  ghost.addEventListener("animationend", (e) => {
    if (e.target === ghost) remove();
  });
  // Belt and braces: never leave a ghost behind (hidden tab, no animation).
  window.setTimeout(remove, prefersReducedMotion() ? 160 : 320);
}

/** Mark the floating panel around `el` as picked-from, so its ghost pulses the chosen row. */
export function markPicked(el: Element | null) {
  el?.closest(".cc-float")?.setAttribute("data-picked", "");
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

/**
 * `measure: "layout"` places the wash from offsetLeft/Top (the container must
 * be the rows' offsetParent) — immune to transforms in flight, e.g. a menu
 * still scaling in or rows still rising in their stagger.
 */
export function useGlide({ measure = "rect" }: { measure?: "rect" | "layout" } = {}): GlideController {
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
    let x: number;
    let y: number;
    let r: { width: number; height: number };
    if (measure === "layout") {
      x = row.offsetLeft;
      y = row.offsetTop;
      r = { width: row.offsetWidth, height: row.offsetHeight };
    } else {
      const c = container.getBoundingClientRect();
      const b = row.getBoundingClientRect();
      x = b.left - c.left + container.scrollLeft;
      y = b.top - c.top + container.scrollTop;
      r = b;
    }
    // Faded out → jump in place, then fade in; visible → spring there.
    wash.dataset.instant = visible.current ? "false" : "true";
    wash.style.transform = `translate(${x}px, ${y}px)`;
    wash.style.width = `${r.width}px`;
    wash.style.height = `${r.height}px`;
    if (!visible.current) void wash.offsetWidth; // commit the jump before fading in
    wash.dataset.instant = "false";
    wash.style.opacity = "1";
    visible.current = true;
  }, [measure]);

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
