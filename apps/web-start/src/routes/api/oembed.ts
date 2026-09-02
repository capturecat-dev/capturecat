import { createFileRoute } from "@tanstack/react-router";

import { API_URL } from "@/lib/api-url";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

/**
 * oEmbed provider (https://oembed.com) for share links, so Notion, Slack,
 * WordPress and friends can turn a pasted capturecat.so/share URL into the
 * embedded player. Discovery <link> tags are emitted by the share page.
 */
export const Route = createFileRoute("/api/oembed")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const params = new URL(request.url).searchParams;
        const url = params.get("url") ?? "";
        const format = params.get("format") ?? "json";
        if (format !== "json") {
          return json({ error: "Only json is supported" }, 501);
        }
        const match = url.match(
          /^https?:\/\/(?:www\.)?capturecat\.so\/share\/([A-Za-z0-9_-]{4,64})/
        );
        if (!match) {
          return json({ error: "Unrecognized url" }, 404);
        }
        const videoId = match[1];

        let title = "CaptureCat recording";
        try {
          const res = await fetch(`${API_URL}/api/video/${videoId}/meta`);
          if (!res.ok) return json({ error: "Not found" }, 404);
          const meta = (await res.json()) as { fileName?: string };
          if (meta.fileName) title = meta.fileName;
        } catch {
          return json({ error: "Not found" }, 404);
        }

        const embedUrl = `https://capturecat.so/embed/${videoId}`;
        return json({
          version: "1.0",
          type: "video",
          provider_name: "CaptureCat",
          provider_url: "https://capturecat.so",
          title,
          html: `<iframe src="${embedUrl}" width="800" height="450" frameborder="0" allow="fullscreen" allowfullscreen style="aspect-ratio:16/9;width:100%;height:auto"></iframe>`,
          width: 800,
          height: 450,
        });
      },
    },
  },
});
