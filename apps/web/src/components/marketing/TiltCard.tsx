import { useRef } from "react";

/**
 * Pointer-tracking 3D tilt for the hero glass card.
 *
 * Transform is written straight to the element (no re-render per mousemove),
 * capped at a few degrees so it reads as depth, not a gimmick. Inert on touch
 * (no mousemove) and under prefers-reduced-motion.
 */
export function TiltCard({
  children,
  className,
  max = 5,
}: {
  children: React.ReactNode;
  className?: string;
  /** Peak rotation in degrees. */
  max?: number;
}) {
  const ref = useRef<HTMLDivElement>(null);

  const onMove = (e: React.MouseEvent<HTMLDivElement>) => {
    const el = ref.current;
    if (!el) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const rect = el.getBoundingClientRect();
    const px = (e.clientX - rect.left) / rect.width - 0.5;
    const py = (e.clientY - rect.top) / rect.height - 0.5;
    el.style.transform = `perspective(1200px) rotateY(${px * max}deg) rotateX(${-py * max}deg)`;
  };

  const onLeave = () => {
    const el = ref.current;
    if (el) el.style.transform = "perspective(1200px) rotateY(0deg) rotateX(0deg)";
  };

  return (
    <div
      ref={ref}
      onMouseMove={onMove}
      onMouseLeave={onLeave}
      className={className}
      style={{ transition: "transform 300ms ease-out", willChange: "transform" }}
    >
      {children}
    </div>
  );
}
