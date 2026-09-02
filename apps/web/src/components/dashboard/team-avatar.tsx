/**
 * Team identity mark: the uploaded logo when the org has one, otherwise
 * initials on a hue derived from the name — same avatar everywhere a team
 * appears (team page, invite landing).
 */
export function TeamAvatar({
  name,
  logo,
  size = 40,
}: {
  name: string;
  logo?: string | null;
  size?: number;
}) {
  const initials = name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]!.toUpperCase())
    .join("");
  let hash = 0;
  for (const ch of name) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
  const hue = hash % 360;

  // Initials render UNDER the image, so a missing/broken logo URL (the
  // invite page always points at the logo endpoint, which 404s until a team
  // uploads one) degrades to initials with no layout shift.
  return (
    <div
      className="relative flex shrink-0 items-center justify-center overflow-hidden rounded-lg font-semibold text-white"
      style={{
        width: size,
        height: size,
        fontSize: size * 0.4,
        background: `linear-gradient(135deg, hsl(${hue} 60% 45%), hsl(${(hue + 40) % 360} 60% 35%))`,
      }}
    >
      <span aria-hidden>{initials || "?"}</span>
      {logo && (
        <img
          src={logo}
          alt={`${name} logo`}
          className="absolute inset-0 h-full w-full object-cover"
          onError={(e) => {
            (e.target as HTMLImageElement).style.display = "none";
          }}
        />
      )}
    </div>
  );
}
