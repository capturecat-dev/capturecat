import { createFileRoute, notFound } from "@tanstack/react-router";

import { API_URL } from "@/lib/api-url";
import { fetchShareMeta } from "@/lib/share-meta";
import SharePlayer, {
  type AnnotationMarker,
} from "@/components/share/share-player";
import ShareGate from "@/components/share/share-gate";

/**
 * Chrome-less player for iframes (oEmbed points here). Same meta gate as the
 * share page; comments never render in an embed — the share page is one click
 * away via the corner badge.
 */
interface VideoMeta {
  videoId: string;
  fileName: string;
  contentType: string;
  durationSeconds: number;
  annotations?: AnnotationMarker[];
  gate?: "open" | "locked" | "expired" | "view_limit" | "paused";
  allowDownload?: boolean;
  brandAccent?: string | null;
  aiChapters?: { start: number; label: string }[];
}

export const Route = createFileRoute("/embed/$videoId")({
  loader: async ({ params }) => {
    let video: VideoMeta | null = null;
    try {
      const raw = await fetchShareMeta({ data: params.videoId });
      video = raw ? (JSON.parse(raw) as VideoMeta) : null;
    } catch {
      video = null;
    }
    if (!video) throw notFound();
    return { video };
  },
  head: () => ({
    meta: [{ name: "robots", content: "noindex" }],
  }),
  component: EmbedPage,
});

function EmbedPage() {
  const { video } = Route.useLoaderData();

  const gated = video.gate && video.gate !== "open";

  return (
    <main className="min-h-screen bg-black p-2">
      <div className="relative">
        {gated ? (
          <ShareGate
            videoId={video.videoId}
            fileName={video.fileName}
            gate={video.gate as "locked" | "expired" | "view_limit" | "paused"}
            brandAccent={video.brandAccent}
            apiUrl={API_URL}
          />
        ) : (
          <SharePlayer
            videoId={video.videoId}
            videoStreamUrl={`${API_URL}/api/video/${video.videoId}`}
            durationSeconds={video.durationSeconds}
            commentsEnabled={false}
            annotations={video.annotations ?? []}
            aiChapters={video.aiChapters ?? []}
            apiUrl={API_URL}
            brandAccent={video.brandAccent}
            downloadUrl={
              video.allowDownload
                ? `${API_URL}/api/video/${video.videoId}/download`
                : null
            }
          />
        )}
        <a
          href={`https://capturecat.so/share/${video.videoId}`}
          target="_blank"
          rel="noreferrer"
          className="absolute right-2 top-2 rounded-md bg-black/60 px-2 py-1 text-[11px] text-white/70 ring-1 ring-white/15 backdrop-blur-sm transition-colors hover:text-white"
        >
          Watch on CaptureCat
        </a>
      </div>
    </main>
  );
}
