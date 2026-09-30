import { useEffect, useRef } from "react";

/**
 * Pauses every CSS animation inside the element while it is offscreen.
 *
 * Writes `data-offscreen` straight onto the node (no React state, no
 * re-render); home.css pauses `[data-offscreen] *`. Server-rendered HTML has
 * no attribute, so without JS the loops simply run.
 */
export function useOffscreenPause<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || typeof IntersectionObserver === "undefined") return;
    const io = new IntersectionObserver(
      ([entry]) => el.toggleAttribute("data-offscreen", !entry.isIntersecting),
      { rootMargin: "120px 0px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);
  return ref;
}

/**
 * Pinned scroll story: the step whose copy crosses a line across the
 * viewport becomes active. Sets `data-step` on the root and `data-active` on
 * that step (the stage's CSS keys every scene off `data-step`). The line
 * sits lower on narrow screens, where the stage is pinned above the copy.
 *
 * This is the stepping path in every browser. Where CSS scroll timelines
 * exist, home.css additionally scrubs the before/after stage continuously.
 */
export function usePinnedSteps<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  useEffect(() => {
    const root = ref.current;
    if (!root || typeof IntersectionObserver === "undefined") return;
    const steps = Array.from(root.querySelectorAll<HTMLElement>("[data-pin-step]"));
    if (steps.length === 0) return;

    const activate = (index: number) => {
      if (root.dataset.step === String(index) && root.hasAttribute("data-ready")) return;
      root.dataset.step = String(index);
      steps.forEach((s, i) => s.toggleAttribute("data-active", i === index));
    };
    root.setAttribute("data-ready", "");
    activate(Number(root.dataset.step ?? 0));

    const wide = window.matchMedia("(min-width: 1024px)");
    let io: IntersectionObserver | null = null;
    const observe = () => {
      io?.disconnect();
      const line = wide.matches ? 52 : 68; // % from the top of the viewport
      io = new IntersectionObserver(
        (entries) => {
          for (const e of entries) {
            if (e.isIntersecting) activate(steps.indexOf(e.target as HTMLElement));
          }
        },
        { rootMargin: `-${line}% 0px -${99 - line}% 0px` },
      );
      steps.forEach((s) => io!.observe(s));
    };
    observe();
    wide.addEventListener("change", observe);
    return () => {
      io?.disconnect();
      wide.removeEventListener("change", observe);
    };
  }, []);
  return ref;
}
