import { useRef } from "react";

/**
 * Cursor spotlight for glass cards.
 *
 * One delegated mousemove on the container writes --mx/--my onto whichever
 * `.glass-spot` card the pointer is over; the glow itself is the `::after`
 * radial in globals.css. No per-card listeners, no re-renders.
 */
export function SpotlightGroup({
  children,
  className,
}: {
  children: React.ReactNode;
  className?: string;
}) {
  const ref = useRef<HTMLDivElement>(null);

  const onMove = (e: React.MouseEvent<HTMLDivElement>) => {
    const card = (e.target as HTMLElement).closest<HTMLElement>(".glass-spot");
    if (!card || !ref.current?.contains(card)) return;
    const rect = card.getBoundingClientRect();
    card.style.setProperty("--mx", `${e.clientX - rect.left}px`);
    card.style.setProperty("--my", `${e.clientY - rect.top}px`);
  };

  return (
    <div ref={ref} onMouseMove={onMove} className={className}>
      {children}
    </div>
  );
}
