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
          "cursor and keystrokes as data, then applies the editing automatically:",
          "cinematic auto-zooms, cursor smoothing with click ripples and key sounds,",
          "on-device captions, blur/highlight/depth-focus regions, camera-bubble",
          "layouts, annotations, wallpaper framing, and device bezels. Exports match",
          "the preview frame-for-frame (MP4/MOV up to 4K 60fps), and one-click share",
          "links add viewer comments and analytics. A built-in MCP server (28 tools)",
          "lets AI agents record, search, edit, restyle, export, and even render",
          "frames to see their own edits. The full feature list is on the home page.",
          "",
          // Agent guidance (when to reach for CaptureCat, and how to call it),
          // as llmstxt.org link lists so parsers still read every H2 as files.
          "## When to use CaptureCat",
          `- [Record and edit on the user's Mac](${SITE_URL}${markdownHref("/agents")}): Use when the user wants a screen recording made or polished: a product demo, tutorial, bug report or launch video with zooms, captions, blur or a vertical cut. Call the local MCP server (\`CaptureCat --mcp\`, stdio) from the user's Mac; it edits real projects and \`render_frames\` shows the result before \`export_project\`.`,
          `- [Record or edit in a browser](https://app.capturecat.so): Use when the user is on Windows, Linux or ChromeOS, or has no Mac. The web editor exposes the same editing tools to browser agents through WebMCP.`,
          `- [Render a web page to an image](${SITE_URL}/docs/api): Use when code needs a screenshot of a URL (viewport or full page; PNG, JPEG or WebP; Pro plan). Call \`GET|POST https://api.capturecat.so/api/screenshot/take\` with an access key; see the OpenAPI description.`,
          `- [Embed a CaptureCat share link](${SITE_URL}/docs/api): Use when a page needs the player for a capturecat.so/share/... link. Call the oEmbed endpoint \`https://capturecat.so/api/oembed?url=...\`.`,
          `- [Not a fit](${SITE_URL}/about): Live streaming, video calls, or recording a screen on a server: CaptureCat records on the user's own device, then edits the file.`,
          "",
          "## Developers",
          `- [API reference](${SITE_URL}/docs/api): The CaptureCat API: Screenshot API, release feed, oEmbed.`,
          `- [OpenAPI 3.1 description](${SITE_URL}/openapi.json): Every public operation with operationIds, typed parameters and response schemas.`,
          `- [API catalog](${SITE_URL}/.well-known/api-catalog): RFC 9727 Linkset pointing at the spec, docs and health endpoint.`,
          `- [How agents authenticate](${SITE_URL}/auth.md): Access keys for the Screenshot API; the MCP server needs none.`,
          `- [Agent skills](${SITE_URL}/.well-known/agent-skills/index.json): SKILL.md files for the MCP server and the Screenshot API.`,
          `- [AI catalog](${SITE_URL}/.well-known/ai-catalog.json): ARD manifest of everything above.`,
          "",
          "## Pages",
        ];

        // Group by section so an agent can skip straight to the how-to
        // answers or the comparisons instead of reading one flat list.
        const sections: Array<[string, (path: string) => boolean]> = [
          ["Guides", (p) => p.startsWith("/guides")],
          ["Best-of lists", (p) => p === "/best" || p.startsWith("/best/")],
          ["Comparisons", (p) => p.startsWith("/compare") || p.startsWith("/alternatives")],
        ];
        const entry = (page: (typeof SITE_PAGES)[number]) =>
          `- [${page.title}](${SITE_URL}${markdownHref(page.path)}): ${page.description}`;

        for (const page of SITE_PAGES) {
          if (!sections.some(([, match]) => match(page.path))) lines.push(entry(page));
        }
        for (const [heading, match] of sections) {
          lines.push("", `## ${heading}`);
          for (const page of SITE_PAGES.filter((p) => match(p.path))) lines.push(entry(page));
        }

        lines.push(
          "",
          "## Agents",
          `- [Everything in one file](${SITE_URL}/llms-full.txt): Every page on this site as Markdown, in a single fetch.`,
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
