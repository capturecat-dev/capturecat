import { Link, createFileRoute, notFound } from "@tanstack/react-router";

import { API_URL } from "@/lib/api-url";

/**
 * Public profile — capturecat.so/{username}.
 *
 * This is the site's LAST route: static segments (/pricing, /app, /share/…)
 * rank higher than this dynamic one, and the API refuses to mint a username
 * that collides with a current or plausible future route, so a claimed name
 * can never shadow a real page.
 *
 * Only videos the API considers listable appear: ready, public, not gated by
 * a password/expiry/view-cap, and profile-visible. A public share link and a
 * listed video are separate choices.
 */
interface ProfileVideo {
  videoId: string;
  title: string;
  summary: string | null;
  durationSeconds: number;
  createdAt: string;
  url: string;
}

interface Profile {
  username: string;
  name: string | null;
  image: string | null;
  bio: string | null;
  website: string | null;
  videos: ProfileVideo[];
}

async function getProfile(username: string): Promise<Profile | null> {
  try {
    const res = await fetch(`${API_URL}/api/u/${encodeURIComponent(username)}`);
    if (!res.ok) return null;
    return (await res.json()) as Profile;
  } catch {
    return null;
  }
}

function formatDuration(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export const Route = createFileRoute("/$username")({
  loader: async ({ params }) => {
    const profile = await getProfile(params.username);
    if (!profile) throw notFound();
    return { profile };
  },
  head: ({ loaderData }) => {
    const profile = loaderData?.profile;
    if (!profile) return { meta: [{ title: "Not found | CaptureCat" }] };

    const displayName = profile.name || `@${profile.username}`;
    const description =
      profile.bio || `Watch videos by ${displayName} on CaptureCat.`;
    const url = `https://capturecat.so/${profile.username}`;
    return {
      meta: [
        { title: `${displayName} | CaptureCat` },
        { name: "description", content: description },
        { property: "og:title", content: displayName },
        { property: "og:description", content: description },
        { property: "og:type", content: "profile" },
        { property: "og:url", content: url },
        { property: "og:site_name", content: "CaptureCat" },
        ...(profile.image
          ? [{ property: "og:image", content: profile.image }]
          : []),
        { name: "twitter:card", content: "summary" },
        { name: "twitter:title", content: displayName },
        { name: "twitter:description", content: description },
        ...(profile.image
          ? [{ name: "twitter:image", content: profile.image }]
          : []),
      ],
      links: [{ rel: "canonical", href: url }],
    };
  },
  component: ProfilePage,
});

function ProfilePage() {
  const { profile } = Route.useLoaderData();

  const displayName = profile.name || `@${profile.username}`;

  return (
    <main className="relative min-h-screen">
      {/* Same ambient wash as the dashboard — this is a CaptureCat page, not
          a bare list. */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 -z-10 overflow-hidden"
      >
        <div
          className="absolute inset-0"
          style={{
            background:
              "radial-gradient(70% 45% at 50% 0%, rgba(120,140,255,0.12), transparent 65%)",
          }}
        />
      </div>

      <div className="mx-auto max-w-5xl px-6 py-16">
        <header className="flex flex-col items-center text-center">
          {profile.image ? (
            <img
              src={profile.image}
              alt=""
              className="h-20 w-20 rounded-full border border-white/10 object-cover"
            />
          ) : (
            <div className="flex h-20 w-20 items-center justify-center rounded-full border border-white/10 bg-white/5 text-2xl font-semibold">
              {displayName.replace(/^@/, "").charAt(0).toUpperCase()}
            </div>
          )}
          <h1 className="mt-4 text-2xl font-semibold tracking-[-0.02em]">{displayName}</h1>
          <p className="text-sm text-muted-foreground">@{profile.username}</p>
          {profile.bio && (
            <p className="mt-3 max-w-xl text-balance text-sm text-muted-foreground">
              {profile.bio}
            </p>
          )}
          {profile.website && (
            <a
              href={profile.website}
              target="_blank"
              // Owner-supplied link on a public page — no ranking signal.
              rel="noopener noreferrer nofollow ugc"
              className="mt-2 text-sm text-primary hover:underline"
            >
              {profile.website.replace(/^https:\/\//, "").replace(/\/$/, "")}
            </a>
          )}
        </header>

        {profile.videos.length === 0 ? (
          <p className="mt-16 text-center text-sm text-muted-foreground">
            No public videos yet.
          </p>
        ) : (
          <div className="mt-12 grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-3">
            {profile.videos.map((video) => {
              // Same frame-extraction trick the share page uses for OG images.
              const streamUrl = `${API_URL}/api/video/${video.videoId}`;
              const poster = `https://capturecat.so/cdn-cgi/media/mode=frame,time=1s,width=640,height=360,fit=cover,format=jpg/${streamUrl}`;
              return (
                <Link
                  key={video.videoId}
                  to="/share/$videoId"
                  params={{ videoId: video.videoId }}
                  className="group overflow-hidden rounded-2xl border border-white/10 bg-white/[0.03] backdrop-blur-2xl transition-colors hover:border-white/20 hover:bg-white/[0.06]"
                >
                  <div className="relative aspect-video overflow-hidden bg-black">
                    <img
                      src={poster}
                      alt=""
                      loading="lazy"
                      className="h-full w-full object-cover transition-transform duration-500 group-hover:scale-105"
                    />
                    <span className="absolute bottom-2 right-2 rounded bg-black/70 px-1.5 py-0.5 text-xs tabular-nums text-white">
                      {formatDuration(video.durationSeconds)}
                    </span>
                  </div>
                  <div className="p-4">
                    <h2 className="line-clamp-2 text-sm font-medium">{video.title}</h2>
                    {video.summary && (
                      <p className="mt-1 line-clamp-2 text-xs text-muted-foreground">
                        {video.summary}
                      </p>
                    )}
                  </div>
                </Link>
              );
            })}
          </div>
        )}

        <footer className="mt-20 text-center">
          <a
            href="https://capturecat.so"
            className="text-sm text-muted-foreground transition-colors hover:text-foreground"
          >
            Made with CaptureCat
          </a>
        </footer>
      </div>
    </main>
  );
}
