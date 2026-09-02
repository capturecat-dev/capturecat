import { Camera, Clapperboard } from "lucide-react";

import { MEDIA_SHOTS, type ShotId } from "@/lib/media-shots";

/**
 * A glass frame that holds a screenshot or screen recording from the app.
 *
 * Until the shot has a `src` in lib/media-shots.ts, it renders a dashed slot
 * with the shot instructions written inside it, so you can walk the site and
 * see exactly what to record for each spot. Once `src` is set, the same frame
 * shows the real media and the instructions disappear.
 */
export function MediaPlaceholder({
  id,
  className = "",
  frame = true,
  radius = "rounded-[22px]",
}: {
  id: ShotId;
  className?: string;
  /** Wrap in the outer glass bezel. Off for tight layouts. */
  frame?: boolean;
  radius?: string;
}) {
  const shot = MEDIA_SHOTS[id];
  const aspectStyle = { aspectRatio: shot.aspect.replace("/", " / ") };

  const inner = shot.src ? (
    shot.kind === "video" ? (
      <video
        className={`h-full w-full object-cover ${radius}`}
        src={shot.src}
        poster={shot.poster}
        autoPlay
        muted
        loop
        playsInline
        preload="metadata"
        aria-label={shot.alt}
      />
    ) : (
      <img
        className={`h-full w-full object-cover ${radius}`}
        src={shot.src}
        alt={shot.alt}
        loading="lazy"
        decoding="async"
      />
    )
  ) : (
    <PlaceholderSlot id={id} radius={radius} />
  );

  if (!frame) {
    return (
      <div className={`relative overflow-hidden ${radius} ${className}`} style={aspectStyle}>
        {inner}
      </div>
    );
  }

  return (
    <div
      className={`relative overflow-hidden rounded-[28px] border border-white/12 bg-white/[0.04] p-2 shadow-[0_40px_120px_-20px_rgba(0,0,0,0.8)] backdrop-blur-2xl ${className}`}
    >
      <span
        aria-hidden
        className="absolute inset-x-10 top-0 h-px bg-gradient-to-r from-transparent via-white/40 to-transparent"
      />
      <div className={`relative overflow-hidden ${radius} bg-[#0e0e10]`} style={aspectStyle}>
        {inner}
      </div>
    </div>
  );
}

function PlaceholderSlot({ id, radius }: { id: ShotId; radius: string }) {
  const shot = MEDIA_SHOTS[id];
  const Icon = shot.kind === "video" ? Clapperboard : Camera;
  const ext = shot.kind === "video" ? "mp4" : "png";

  return (
    <div
      className={`absolute inset-0 flex flex-col justify-between ${radius} border border-dashed border-white/20 bg-[radial-gradient(80%_60%_at_50%_0%,rgba(120,140,255,0.10),transparent_70%)] p-4 md:p-5`}
    >
      <div className="flex items-center justify-between gap-3">
        <span className="inline-flex items-center gap-1.5 rounded-full border border-white/12 bg-white/[0.07] px-2.5 py-1 text-[11px] font-medium uppercase tracking-[0.08em] text-muted-foreground">
          <Icon className="h-3 w-3" strokeWidth={2} />
          {shot.kind === "video" ? "Screen recording" : "Screenshot"}
        </span>
        <code className="hidden rounded bg-black/40 px-2 py-1 text-[11px] text-muted-foreground/80 sm:inline-block">
          /media/{id}.{ext}
        </code>
      </div>
      <div>
        <p className="text-[15px] font-medium text-foreground">{shot.title}</p>
        <p className="mt-1 line-clamp-4 max-w-md text-[13px] leading-relaxed text-muted-foreground">
          {shot.shot}
        </p>
      </div>
    </div>
  );
}
