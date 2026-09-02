import { createFileRoute } from "@tanstack/react-router";

import { SITE_PAGES, SITE_URL, markdownHref } from "@/lib/site-content";

/**
 * /llms.txt — the llmstxt.org discovery file.
 *
 * A single H1, a blockquote summary, then a list of the site's pages linking to
 * their Markdown renderings (the spec prefers Markdown URLs). Generated from the
 * same registry that drives robots.txt, the sitemap, and the /*.md routes, so it
 * can never list a page that no longer exists.
 */
export const Route = createFileRoute("/llms.txt")({
  server: {
    handlers: {
      GET: () => {
        const home = SITE_PAGES.find((p) => p.path === "/");

        const lines: string[] = [
          "# CaptureCat",
          "",
          `> ${home?.description ?? "A native screen recorder for Mac that edits itself."}`,
          "",
          "CaptureCat is a screen recorder for Mac that edits itself. It records any",
          "display, window, area, iPhone/iPad, or web page by URL, capturing clicks,",
          "cursor and keystrokes as data — then applies the editing automatically:",
          "cinematic auto-zooms, cursor smoothing with click ripples and key sounds,",
          "on-device captions, blur/highlight/depth-focus regions, camera-bubble",
          "layouts, annotations, wallpaper framing, and device bezels. Exports match",
          "the preview frame-for-frame (MP4/MOV up to 4K 60fps), and one-click share",
          "links add viewer comments and analytics. A built-in MCP server (17 tools)",
          "lets AI agents record, search, edit, restyle, export, and even render",
          "frames to see their own edits. The full feature list is on the home page.",
          "",
          "## Pages",
        ];

        for (const page of SITE_PAGES) {
          lines.push(
            `- [${page.title}](${SITE_URL}${markdownHref(page.path)}): ${page.description}`
          );
        }

        lines.push(
          "",
          "## Agents",
          `- [Agents & MCP](${SITE_URL}${markdownHref("/agents")}): How to connect Claude, ChatGPT, Cursor, Copilot, and Windsurf to CaptureCat's MCP server.`,
          ""
        );

        return new Response(lines.join("\n"), {
          status: 200,
          headers: {
            "Content-Type": "text/plain; charset=utf-8",
            "Cache-Control": "public, max-age=3600, s-maxage=86400",
          },
        });
      },
    },
  },
});
