/**
 * The dashboard's motion helpers — the recording bar's vocabulary
 * (app.css `--rec-*`) applied to the rest of /app. Everything here moves
 * with transform and opacity only, and dashboard.css drops the movement under
 * prefers-reduced-motion.
 *
 *   glide   ONE hover wash per list that glides to whichever `[data-glide]`
 *           row is under the pointer (CCGlideHighlight), fading in from
 *           nothing, out when the pointer leaves
 *   pill    ONE selection pill that springs to the active `[data-pill-key]`
 *   pause   loops inside an element stop while it is offscreen
 */
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type PointerEvent as ReactPointerEvent,
} from "react";

import { cn } from "@/lib/utils";

/**
 * Pauses every CSS animation inside the element while it is offscreen: writes
 * `data-offscreen` straight onto the node (no React state, no re-render);
 * dashboard.css pauses `[data-offscreen] *`.
 */
export function useOffscreenPause<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || typeof IntersectionObserver === "undefined") return;
    const io = new IntersectionObserver(
      ([entry]) => el.toggleAttribute("data-offscreen", !entry.isIntersecting),
      { rootMargin: "80px 0px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);
  return ref;
}

interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
}

function boxOf(el: HTMLElement, host: HTMLElement): Box {
  const a = el.getBoundingClientRect();
  const b = host.getBoundingClientRect();
  return { x: a.left - b.left, y: a.top - b.top, w: a.width, h: a.height };
}

/**
 * The hover wash. Spread `handlers` on a `relative` host and render `wash`
 * inside it; rows opt in with `data-glide`. The wash's SIZE snaps (rows in a
 * list share one shape) and only its position and opacity animate.
 */
export function useGlide({ className, radius = "0.75rem" }: { className?: string; radius?: string } = {}) {
  const [box, setBox] = useState<Box | null>(null);
  const [visible, setVisible] = useState(false);
  const snap = useRef(true);
  const onPointerOver = useCallback((e: ReactPointerEvent<HTMLElement>) => {
    const row = (e.target as HTMLElement).closest<HTMLElement>("[data-glide]");
    const host = e.currentTarget;
    if (!row || !host.contains(row) || row.matches(":disabled,[aria-disabled=true]")) return;
    setBox(boxOf(row, host));
    setVisible((was) => {
      snap.current = !was;
      return true;
    });
  }, []);
  const onPointerLeave = useCallback(() => {
    setVisible(false);
    snap.current = true;
  }, []);
  const wash = box ? (
    <span
      aria-hidden
      className={cn("dsh-glide-wash", className)}
      style={{
        width: box.w,
        height: box.h,
        borderRadius: radius,
        transform: `translate3d(${box.x}px, ${box.y}px, 0)`,
        opacity: visible ? 1 : 0,
        transition: snap.current
          ? "opacity var(--rec-fade) ease-out"
          : "transform 320ms var(--rec-settle), opacity var(--rec-fade) ease-out",
      }}
    />
  ) : null;
  return { wash, handlers: { onPointerOver, onPointerLeave } };
}

/**
 * The selection pill: springs to the `[data-pill-key="<active>"]` child of
 * the host. The first placement lands without motion; later moves spring on
 * the settle curve (transform only — keys in a group share one size).
 */
export function usePill<T extends HTMLElement>(active: string | null, deps: unknown[] = []) {
  // A callback ref: the host often mounts AFTER this hook (a page swaps its
  // skeleton for the real toolbar), and the pill must measure when it does.
  const [host, hostRef] = useState<T | null>(null);
  const [box, setBox] = useState<Box | null>(null);
  const settled = useRef(false);
  useLayoutEffect(() => {
    if (!host || active === null) {
      setBox(null);
      return;
    }
    const measure = () => {
      const el = host.querySelector<HTMLElement>(`[data-pill-key="${CSS.escape(active)}"]`);
      setBox(el ? boxOf(el, host) : null);
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(host);
    return () => ro.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [host, active, ...deps]);
  useEffect(() => {
    // First placement lands without motion; later moves spring.
    if (!host) return;
    const t = window.setTimeout(() => (settled.current = true), 0);
    return () => window.clearTimeout(t);
  }, [host]);
  const style: CSSProperties | undefined = box
    ? {
        width: box.w,
        height: box.h,
        transform: `translate3d(${box.x}px, ${box.y}px, 0)`,
        transition: settled.current ? "transform 380ms var(--rec-settle)" : "none",
      }
    : undefined;
  return { hostRef, pillStyle: style };
}
