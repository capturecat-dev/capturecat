import { createFileRoute } from "@tanstack/react-router";

import { API_URL } from "@/lib/api-url";
import { SITE_URL } from "@/lib/site-url";

/**
 * Markdown twin of the public share page, for agents and crawlers.
 *
 * Public URL is /share/:videoId.md; server.ts rewrites it here. Mirrors the
 * style of src/lib/markdown-pages.ts (text/markdown + canonical), but the
 * content is per-video: metadata, AI summary/chapters when present, and the
 * full timestamped transcript from the API.
 *
 * Privacy: the meta endpoint 404s private videos, and a gated (password /
 * expired / view-limit) meta carries gate !== "open" — both become a plain
 * 404 here so nothing leaks into the markdown surface.
 */

interface ShareMeta {
  videoId: string;
  fileName: string;
  durationSeconds: number;
  createdAt: string;
  gate?: string;
  aiTitle?: string | null;
  aiSummary?: string | null;
  aiChapters?: { start: number; label: string }[];
  hasTranscript?: boolean;
}

interface TranscriptSegment {
  start: number;
  end: number;
  text: string;
}

function mmss(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds || 0));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

function notFoundMd(): Response {
  return new Response("# Not found\n\nNo Markdown rendering for this video.\n", {
    status: 404,
    headers: { "Content-Type": "text/markdown; charset=utf-8" },
  });
}

export const Route = createFileRoute("/md-share/$videoId")({
  server: {
    handlers: {
      GET: async ({ params }) => {
        const videoId = (params as { videoId: string }).videoId;
        if (!/^[A-Za-z0-9_-]{4,64}$/.test(videoId)) return notFoundMd();

        let meta: ShareMeta | null = null;
        try {
          const res = await fetch(
            `${API_URL}/api/video/${encodeURIComponent(videoId)}/meta`
          );
          if (res.ok) meta = (await res.json()) as ShareMeta;
        } catch {
          meta = null;
        }
        // Private → the API already 404'd; gated → don't leak anything.
        if (!meta || (meta.gate && meta.gate !== "open")) return notFoundMd();

        let segments: TranscriptSegment[] = [];
        if (meta.hasTranscript) {
          try {
            const res = await fetch(
              `${API_URL}/api/video/${encodeURIComponent(videoId)}/transcript`
            );
            if (res.ok) {
              const body = (await res.json()) as { segments?: TranscriptSegment[] };
              if (Array.isArray(body.segments)) segments = body.segments;
            }
          } catch {
            segments = [];
          }
        }

        const shareUrl = `${SITE_URL}/share/${meta.videoId}`;
        const embedUrl = `${SITE_URL}/embed/${meta.videoId}`;
        const title = meta.aiTitle || meta.fileName;

        const lines: string[] = [`# ${title}`, ""];
        const facts = [
          `Duration: ${mmss(meta.durationSeconds)}`,
          meta.createdAt ? `Published: ${meta.createdAt}` : null,
        ].filter(Boolean);
        lines.push(facts.join(" · "), "");

        if (meta.aiSummary) {
          lines.push("## Summary", "", meta.aiSummary.trim(), "");
        }

        if (Array.isArray(meta.aiChapters) && meta.aiChapters.length > 0) {
          lines.push("## Chapters", "");
          for (const ch of meta.aiChapters) {
            lines.push(`- ${mmss(ch.start)} — ${ch.label}`);
          }
          lines.push("");
        }

        lines.push("## Transcript", "");
        if (segments.length > 0) {
          for (const seg of segments) {
            const text = (seg.text ?? "").trim();
            if (text) lines.push(`${mmss(seg.start)}  ${text}`);
          }
        } else {
          lines.push("No transcript is available for this video.");
        }
        lines.push("");

        lines.push("---", "", `Watch: ${shareUrl}`, `Embed: ${embedUrl}`, "");

        const header = `<!-- canonical: ${shareUrl} -->\n\n`;
        return new Response(header + lines.join("\n"), {
          status: 200,
          headers: {
            "Content-Type": "text/markdown; charset=utf-8",
            Link: `<${shareUrl}>; rel="canonical"`,
            // Public but shortish: transcripts and settings can change.
            "Cache-Control": "public, max-age=300, s-maxage=3600",
            "X-Robots-Tag": "all",
          },
        });
      },
    },
  },
});
