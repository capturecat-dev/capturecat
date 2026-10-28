import { useState } from "react";

import { avatarColor, avatarInitial } from "@/lib/share/comments";

/**
 * A commenter's avatar: their signed-in picture when the API has one (it
 * only ever comes from their session), otherwise a coloured initial derived
 * from the name — same name, same colour, everywhere.
 */
export function CommentAvatar({
  name,
  image,
  size = 28,
  className = "",
  ring = "ring-1 ring-white/10",
}: {
  name: string;
  image?: string | null;
  size?: number;
  className?: string;
  ring?: string;
}) {
  const [failed, setFailed] = useState(false);
  const common = `inline-grid shrink-0 place-items-center overflow-hidden rounded-full ${ring} ${className}`;
  if (image && !failed) {
    return (
      <img
        src={image}
        alt=""
        aria-hidden
        width={size}
        height={size}
        // Provider avatar hosts (Google, GitHub) refuse some referrers.
        referrerPolicy="no-referrer"
        loading="lazy"
        draggable={false}
        onError={() => setFailed(true)}
        className={`${common} bg-white/10 object-cover`}
        style={{ width: size, height: size }}
      />
    );
  }
  return (
    <span
      aria-hidden
      className={`${common} select-none font-semibold leading-none text-white`}
      style={{
        width: size,
        height: size,
        backgroundColor: avatarColor(name),
        fontSize: Math.round(size * 0.44),
      }}
    >
      {avatarInitial(name)}
    </span>
  );
}

/** The quiet "Owner" tag beside the video owner's name. */
export function OwnerBadge({ accent }: { accent: string }) {
  return (
    <span className="inline-flex items-center gap-1 rounded-full bg-white/[0.09] px-1.5 py-px text-[10px] font-semibold uppercase tracking-[0.06em] text-white/75 ring-1 ring-white/10">
      <span aria-hidden className="h-1.5 w-1.5 rounded-full" style={{ backgroundColor: accent }} />
      Owner
    </span>
  );
}
