import { createFileRoute } from "@tanstack/react-router";

import { API_URL } from "@/lib/api-url";
import { SITE_URL } from "@/lib/site-url";
import type { AnnotationShape } from "@/lib/share/annotation";
import { buildThreads, readComment, type ShareComment } from "@/lib/share/comments";

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
 *
 * Comments (when the owner turned them on) are listed as threads: each
 * top-level comment at its timestamp, its replies nested one level, the
 * owner's marked, and an on-frame drawing summarized in words (its text
 * labels quoted). Viewer text is escaped so it cannot inject Markdown.
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
  commentsEnabled?: boolean;
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

/** Viewer-written text → one inert Markdown line: no links, HTML, emphasis,
 *  code or tables, and no line breaks to start a new block (a heading or
 *  list can only begin a line, and every line here starts with our prefix). */
function mdText(text: string): string {
  return text
    .replace(/\s+/g, " ")
    .trim()
    .replace(/([\\`*_\[\]<>|~])/g, "\\$1");
}

const SHAPE_WORDS: Record<AnnotationShape["kind"], string> = {
  pen: "freehand mark",
  highlight: "highlight",
  arrow: "arrow",
  rect: "box",
  ellipse: "circle",
  text: "label",
};

/** "drawing on the frame: 2 arrows, a box, label "Fix this"". */
function describeDrawing(comment: ShareComment): string {
  const shapes = comment.annotation?.shapes ?? [];
  if (shapes.length === 0) return "";
  const counts = new Map<string, number>();
  for (const s of shapes) {
    if (s.kind !== "text") counts.set(SHAPE_WORDS[s.kind], (counts.get(SHAPE_WORDS[s.kind]) ?? 0) + 1);
  }
  const parts = [...counts].map(([word, n]) => (n === 1 ? `1 ${word}` : `${n} ${word}${word.endsWith("x") ? "es" : "s"}`));
  for (const s of shapes) {
    if (s.kind === "text") parts.push(`label "${mdText(s.text)}"`);
  }
  return ` _(drew on the frame: ${parts.join(", ")})_`;
}

function commentLine(c: ShareComment): string {
  const who = `**${mdText(c.authorName)}**${c.isOwner ? " (owner)" : ""}`;
  return `${who}: ${mdText(c.body)}${describeDrawing(c)}`;
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

        let comments: ShareComment[] = [];
        if (meta.commentsEnabled) {
          try {
            const res = await fetch(
              `${API_URL}/api/video/${encodeURIComponent(videoId)}/comments`
            );
            if (res.ok) {
              const body = (await res.json()) as { comments?: unknown[] };
              comments = (body.comments ?? [])
                .map(readComment)
                .filter((c): c is ShareComment => c !== null);
            }
          } catch {
            comments = [];
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

        if (meta.commentsEnabled) {
          lines.push("## Comments", "");
          const threads = buildThreads(comments);
          if (threads.length === 0) {
            lines.push("No comments yet.");
          }
          for (const { comment, replies } of threads) {
            lines.push(`- ${mmss(comment.videoTime)} — ${commentLine(comment)}`);
            for (const r of replies) {
              lines.push(`  - ↳ ${commentLine(r)}`);
            }
          }
          lines.push("");
        }

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
