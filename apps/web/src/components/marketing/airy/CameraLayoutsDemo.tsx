import { useEffect, useRef } from "react";

import { CameraBubble, Canvas } from "../home/demo/parts";

/**
 * The camera layouts as one 12 s loop on the editor's canvas: the bubble,
 * the cutout (background removed), the pop-out card (head above the card)
 * and the full-height Split Screen (docs/camera-cutout.md §12). Motion lives
 * in styles/airy.css; it only plays once mounted and on screen.
 */
export function CameraLayoutsDemo() {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.setAttribute("data-playing", "");
    if (typeof IntersectionObserver === "undefined") return;
    const io = new IntersectionObserver(
      ([entry]) => el.toggleAttribute("data-offscreen", !entry.isIntersecting),
      { rootMargin: "120px 0px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);

  return (
    <div ref={ref} className="air-lay">
      <div className="overflow-hidden rounded-[20px] md:rounded-[24px]">
        <Canvas script="layouts">
          <CameraBubble />
          <div className="air-lay-layer air-lay-cutout">
            <Person />
          </div>
          <div className="air-lay-layer air-lay-pop">
            <div className="air-lay-pop-card" />
            <div className="air-lay-pop-person">
              <Person />
            </div>
          </div>
          <div className="air-lay-layer air-lay-tile">
            <Person backdrop />
          </div>
        </Canvas>
      </div>
      <div className="air-lay-chips mt-4" aria-hidden>
        <span className="air-lay-chip">Bubble</span>
        <span className="air-lay-chip">Cutout</span>
        <span className="air-lay-chip">Pop-out card</span>
        <span className="air-lay-chip">Split Screen</span>
      </div>
      <p className="sr-only">
        A recreation of CaptureCat's camera layouts: a rounded camera bubble, then the same person with the
        background removed, then on a gradient card with the head breaking out of the top, then a full-height
        split with the screen on the left and the camera on the right.
      </p>
    </div>
  );
}

/** The stylised presenter (parts.tsx's webcam face) without — or with — a room behind. */
function Person({ backdrop = false }: { backdrop?: boolean }) {
  const id = backdrop ? "airPersonRoom" : "airPersonCut";
  return (
    <svg className="air-lay-person" viewBox="0 0 100 100" preserveAspectRatio="xMidYMax slice" aria-hidden>
      <defs>
        <linearGradient id={`${id}Skin`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#f2c6a4" />
          <stop offset="1" stopColor="#d9a07e" />
        </linearGradient>
        {backdrop && (
          <linearGradient id={`${id}Bg`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#3a4a63" />
            <stop offset="1" stopColor="#1f2636" />
          </linearGradient>
        )}
      </defs>
      {backdrop && (
        <>
          <rect width="100" height="100" fill={`url(#${id}Bg)`} />
          <circle cx="76" cy="20" r="24" fill="#ffd9a0" opacity="0.18" />
          <rect x="8" y="14" width="18" height="30" rx="2" fill="#ffffff" opacity="0.06" />
        </>
      )}
      <path d="M12 104c2-24 18-37 38-37s36 13 38 37z" fill="#5b7cfa" />
      <path d="M40 62h20v11a10 10 0 0 1-20 0z" fill="#d9a07e" />
      <ellipse cx="50" cy="41" rx="17" ry="20" fill={`url(#${id}Skin)`} />
      <path d="M32 38c0-14 8-22 18-22 11 0 19 8 18 21-4-7-10-10-18-10s-14 3-18 11z" fill="#2b2320" />
    </svg>
  );
}
