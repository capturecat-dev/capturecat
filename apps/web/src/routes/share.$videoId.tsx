import { createFileRoute, notFound } from "@tanstack/react-router";

import { API_URL } from "@/lib/api-url";
import { jsonLd } from "@/lib/json-ld";
import SharePlayer, {
  type AnnotationMarker,
} from "@/components/share/share-player";
import ShareGate from "@/components/share/share-gate";
import CaptureCatMark from "@/components/brand/CaptureCatMark";

/**
 * Public share page.
 *
 * Reads GET /api/video/:id/meta rather than Firestore directly. Two reasons
 * beyond removing firebase-admin: that Firestore collection stopped receiving
 * writes when uploads moved to D1, so this page was rendering frozen data; and
 * the endpoint applies the SAME `ready && !isPrivate` gate the byte route
 * applies, so the page and the stream can never disagree.
 *
 * The endpoint deliberately withholds `uid` and `r2Key` — the old Firestore
 * read pulled both into the rendered page.
 */
interface VideoMeta {
  videoId: string;
  fileName: string;
  contentType: string;
  fileSizeBytes: number;
  durationSeconds: number;
  createdAt: string;
  commentsEnabled?: boolean;
  annotations?: AnnotationMarker[];
  /** "open" | "locked" | "expired" | "view_limit" — gated metas carry only
   *  videoId/fileName/gate/brandAccent. */
  gate?: "open" | "locked" | "expired" | "view_limit";
  allowDownload?: boolean;
  brandAccent?: string | null;
  aiTitle?: string | null;
  aiSummary?: string | null;
  aiChapters?: { start: number; label: string }[];
  hasTranscript?: boolean;
  currentVersion?: number;
  showVersionHistory?: boolean;
  ctaLabel?: string | null;
  ctaUrl?: string | null;
  /** Owner-uploaded custom thumbnail (absolute API URL), or null. */
  thumbnailUrl?: string | null;
  versions?: { version: number; createdAt: string; durationSeconds: number; current: boolean }[];
}

/** Seconds → ISO 8601 duration ("PT1M32S") for schema.org VideoObject. */
function isoDuration(seconds: number): string {
  const s = Math.max(0, Math.round(seconds || 0));
  const m = Math.floor(s / 60);
  const h = Math.floor(m / 60);
  return `PT${h > 0 ? `${h}H` : ""}${m % 60 > 0 || h > 0 ? `${m % 60}M` : ""}${s % 60}S`;
}

async function getVideo(videoId: string): Promise<VideoMeta | null> {
  try {
    const res = await fetch(
      `${API_URL}/api/video/${encodeURIComponent(videoId)}/meta`
    );
    if (!res.ok) return null;
    return (await res.json()) as VideoMeta;
  } catch {
    return null;
  }
}

export const Route = createFileRoute("/share/$videoId")({
  validateSearch: (search: Record<string, unknown>): { t?: string; v?: string } => ({
    t: typeof search.t === "string" || typeof search.t === "number" ? String(search.t) : undefined,
    v: typeof search.v === "string" || typeof search.v === "number" ? String(search.v) : undefined,
  }),
  loader: async ({ params }) => {
    const video = await getVideo(params.videoId);
    if (!video) throw notFound();
    return { video };
  },
  head: ({ loaderData }) => {
    const video = loaderData?.video;
    if (!video) return { meta: [{ title: "Video not found | CaptureCat" }] };

    // A gated (password/expired/view-limit) video must not leak metadata to
    // crawlers: minimal head, noindex, no OpenGraph/video/JSON-LD.
    if (video.gate && video.gate !== "open") {
      return {
        meta: [
          { title: "Private video — CaptureCat" },
          { name: "robots", content: "noindex" },
        ],
      };
    }

    const videoStreamUrl = `https://api.capturecat.so/api/video/${video.videoId}`;
    const embedUrl = `https://capturecat.so/embed/${video.videoId}`;
    const shareUrl = `https://capturecat.so/share/${video.videoId}`;
    // A custom thumbnail wins; otherwise Media Transformations extracts a frame.
    const thumbnailUrl =
      video.thumbnailUrl ??
      `https://capturecat.so/cdn-cgi/media/mode=frame,time=1s,width=1200,height=630,fit=cover,format=jpg/${videoStreamUrl}`;
    const description = `Watch "${video.fileName}" — shared via CaptureCat`;

    return {
      meta: [
        { title: `${video.fileName} | CaptureCat` },
        { name: "description", content: description },
        { property: "og:title", content: video.fileName },
        { property: "og:description", content: description },
        { property: "og:type", content: "video.other" },
        { property: "og:url", content: shareUrl },
        { property: "og:site_name", content: "CaptureCat" },
        { property: "og:image", content: thumbnailUrl },
        { property: "og:image:width", content: "1200" },
        { property: "og:image:height", content: "630" },
        { property: "og:image:alt", content: video.fileName },
        { property: "og:video", content: embedUrl },
        { property: "og:video:secure_url", content: embedUrl },
        { property: "og:video:type", content: "text/html" },
        { property: "og:video:width", content: "1280" },
        { property: "og:video:height", content: "720" },
        { property: "video:duration", content: String(Math.round(video.durationSeconds || 0)) },
        { name: "twitter:card", content: "player" },
        { name: "twitter:title", content: video.fileName },
        { name: "twitter:description", content: description },
        { name: "twitter:image", content: thumbnailUrl },
        { name: "twitter:image:alt", content: video.fileName },
        { name: "twitter:player", content: embedUrl },
        { name: "twitter:player:width", content: "1280" },
        { name: "twitter:player:height", content: "720" },
        { name: "twitter:player:stream", content: videoStreamUrl },
        { name: "twitter:player:stream:content_type", content: "video/mp4" },
      ],
      links: [
        { rel: "canonical", href: shareUrl },
        {
          rel: "alternate",
          type: "application/json+oembed",
          href: `https://capturecat.so/api/oembed?url=${encodeURIComponent(shareUrl)}&format=json`,
        },
        {
          rel: "alternate",
          type: "text/markdown",
          href: `/share/${video.videoId}.md`,
        },
      ],
      scripts: [
        {
          type: "application/ld+json",
          children: jsonLd({
            "@context": "https://schema.org",
            "@type": "VideoObject",
            name: video.aiTitle || video.fileName,
            description: video.aiSummary || description,
            uploadDate: video.createdAt,
            duration: isoDuration(video.durationSeconds),
            thumbnailUrl,
            contentUrl: videoStreamUrl,
            embedUrl,
            url: shareUrl,
          }),
        },
      ],
    };
  },
  component: SharePage,
});

/**
 * Viewer-facing title. AI titles win in the caller; this cleans raw upload
 * filenames: extension stripped, and the app's own `capturecat-share-<UUID>`
 * pattern collapses to "Untitled recording" instead of showing the UUID.
 */
function prettyFileName(fileName: string): string {
  const base = fileName.replace(/\.[A-Za-z0-9]{2,5}$/, "").trim();
  if (/^capturecat-share-[0-9a-fA-F-]{8,}$/.test(base) || base.length === 0) {
    return "Untitled recording";
  }
  return base;
}

function SharePage() {
  const { video } = Route.useLoaderData();
  const { t, v } = Route.useSearch();
  const startAt = t && isFinite(Number(t)) ? Math.max(0, Number(t)) : null;

  // Version history (owner opt-in). ?v=N plays an older version; anything not
  // in the published list falls back to the live version.
  const versions = video.showVersionHistory ? (video.versions ?? []) : [];
  const requestedVersion = v ? parseInt(v, 10) : NaN;
  const playVersion = versions.some((ver) => ver.version === requestedVersion)
    ? requestedVersion
    : (video.currentVersion ?? 1);

  // API_URL, not a hardcoded origin: in production these are the same value, but
  // a local dev record lives only in the local D1 and can only be streamed from
  // the local API. The OpenGraph URLs above stay absolute — crawlers need those.
  // Pinning ?v= keeps the byte URL immutable-cacheable AND changes it the
  // moment a replace upload flips the live version.
  const videoStreamUrl = `${API_URL}/api/video/${video.videoId}?v=${playVersion}`;

  const gated = video.gate && video.gate !== "open";
  const accent = video.brandAccent || null;
  return (
    <main className="relative isolate min-h-screen overflow-x-clip bg-[#08090d] text-white">
      {/* Ambient light — same layered washes as the app shell, tinted toward
          the owner's brand accent when the video carries one. */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 -z-10"
        style={{
          background:
            "radial-gradient(90% 60% at 50% -10%, rgba(120,140,255,0.10), transparent 60%)," +
            "radial-gradient(60% 40% at 90% 20%, rgba(80,220,255,0.06), transparent 55%)" +
            (accent
              ? `,radial-gradient(70% 45% at 10% 0%, ${accent}14, transparent 60%)`
              : ""),
        }}
      />

      {/* Slim top bar — the video is the hero, the brand just signs it. */}
      <header className="mx-auto flex w-full max-w-[1280px] items-center justify-between gap-4 px-4 py-3.5 sm:px-6">
        <a
          href="https://capturecat.so"
          className="flex items-center gap-2.5 text-[15px] font-semibold tracking-[-0.01em] text-white/90 transition-opacity hover:opacity-80"
        >
          <CaptureCatMark size={26} />
          CaptureCat
        </a>
        <a
          href="https://capturecat.so"
          className="rounded-full border border-white/12 bg-white/[0.04] px-4 py-1.5 text-xs font-medium text-white/75 backdrop-blur-sm transition-colors hover:border-white/25 hover:bg-white/[0.09] hover:text-white"
        >
          Record your own
        </a>
      </header>

      <div className="mx-auto w-full max-w-[1280px] px-3 pb-14 pt-1 sm:px-6">
        {gated ? (
          <ShareGate
            videoId={video.videoId}
            fileName={video.fileName}
            gate={video.gate as "locked" | "expired" | "view_limit"}
            brandAccent={video.brandAccent}
            apiUrl={API_URL}
          />
        ) : (
        <SharePlayer
          videoId={video.videoId}
          videoStreamUrl={videoStreamUrl}
          durationSeconds={video.durationSeconds}
          commentsEnabled={video.commentsEnabled === true}
          annotations={video.annotations ?? []}
          brandAccent={video.brandAccent}
          downloadUrl={
            video.allowDownload
              ? `${API_URL}/api/video/${video.videoId}/download`
              : null
          }
          aiChapters={video.aiChapters ?? []}
          hasTranscript={video.hasTranscript === true}
          apiUrl={API_URL}
          startAt={startAt}
          ctaLabel={video.ctaLabel ?? null}
          ctaUrl={video.ctaUrl ?? null}
          title={video.aiTitle || prettyFileName(video.fileName)}
          summary={video.aiSummary ?? null}
          createdAt={video.createdAt ?? null}
          versions={versions}
          playVersion={playVersion}
        />
        )}
        {/* Title, summary, and version history render inside SharePlayer's
            watch-page shell now — the page keeps only the quiet footer. */}
        <footer className="mt-12 border-t border-white/[0.06] pt-6 text-center">
          <a
            href="https://capturecat.so"
            className="text-xs text-white/35 transition-colors hover:text-white/70"
          >
            Made with CaptureCat
          </a>
        </footer>
      </div>
    </main>
  );
}
