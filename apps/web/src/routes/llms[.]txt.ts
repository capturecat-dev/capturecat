import { createFileRoute } from "@tanstack/react-router";

import { SITE_PAGES, SITE_URL, markdownHref } from "@/lib/site-content";
import { MCP_ENDPOINT } from "@/lib/agent-access";
import {
  CHANGELOG_DESCRIPTION,
  CHANGELOG_FEED_PATH,
  CHANGELOG_PATH,
  changelogEntryPath,
  changelogMarkdownHref,
  fetchChangelog,
} from "@/lib/changelog/site";

/**
 * /llms.txt — the llmstxt.org discovery file.
 *
 * A single H1, a blockquote summary, then a list of the site's pages linking to
 * their Markdown renderings (the spec prefers Markdown URLs). Generated from the
 * same registry that drives robots.txt, the sitemap, and the /*.md routes, so it
 * can never list a page that no longer exists. The changelog (D1, not the
 * registry) is listed from the API: its twin, its feed and the latest entries.
 */
export const Route = createFileRoute("/llms.txt")({
  server: {
    handlers: {
      GET: async () => {
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
          "links add viewer comments and analytics. A built-in MCP server (30 tools)",
          "lets AI agents record, search, edit, restyle, export, and even render",
          "frames to see their own edits. The full feature list is on the home page.",
          "",
          // Agent guidance (when to reach for CaptureCat, and how to call it),
          // as llmstxt.org link lists so parsers still read every H2 as files.
          "## When to use CaptureCat",
          `- [Record and edit on the user's Mac](${SITE_URL}${markdownHref("/agents")}): Use when the user wants a screen recording made or polished: a product demo, tutorial, bug report or launch video with zooms, captions, blur or a vertical cut. Call the local MCP server (\`CaptureCat --mcp\`, stdio) from the user's Mac; it edits real projects and \`render_frames\` shows the result before \`export_project\`.`,
          `- [Work with the user's shared videos from a cloud agent](${SITE_URL}/auth.md): Use when an agent that is not on the user's Mac (Claude.ai, Claude Code over HTTP, ChatGPT, a scheduled job) needs their CaptureCat videos: list them, read transcripts, AI summaries, comments and analytics, reply to viewers, change share settings, manage playlists, and edit their cloud projects (zooms, cuts, trims, speed, blur, annotations, style, version history) without the editor open. Claude.ai and ChatGPT custom connectors need only the URL \`${MCP_ENDPOINT}\`: they sign in with CaptureCat (OAuth 2.1, PKCE). Other clients send \`Authorization: Bearer cc_pat_…\`, a scoped agent token the user creates in Settings → Agent access. Posting a comment or making a video more visible asks the user first (an approve link).`,
          `- [Record or edit in a browser](https://app.capturecat.so): Use when the user is on Windows, Linux or ChromeOS, or has no Mac. The web editor exposes the same editing tools to browser agents through WebMCP.`,
          `- [Render a web page to an image](${SITE_URL}/docs/api): Use when code needs a screenshot of a URL (viewport or full page; PNG, JPEG or WebP; Pro plan). Call \`GET|POST https://api.capturecat.so/api/screenshot/take\` with an access key; see the OpenAPI description.`,
          `- [Embed a CaptureCat share link](${SITE_URL}/docs/api): Use when a page needs the player for a capturecat.so/share/... link. Call the oEmbed endpoint \`https://capturecat.so/api/oembed?url=...\`.`,
          `- [Not a fit](${SITE_URL}/about): Live streaming, video calls, or recording a screen on a server: CaptureCat records on the user's own device, then edits the file.`,
          "",
          "## Developers",
          `- [API reference](${SITE_URL}/docs/api): The CaptureCat API: Screenshot API, release feed, oEmbed.`,
          `- [OpenAPI 3.1 description](${SITE_URL}/openapi.json): Every public operation with operationIds, typed parameters and response schemas.`,
          `- [API catalog](${SITE_URL}/.well-known/api-catalog): RFC 9727 Linkset pointing at the spec, docs and health endpoint.`,
          `- [How agents authenticate](${SITE_URL}/auth.md): OAuth 2.1 sign-in (Claude.ai / ChatGPT connectors) or scoped agent tokens for the remote MCP server, "ask me first" approvals, signed webhooks, access keys for the Screenshot API; the local MCP server needs none.`,
          `- [Remote MCP server card](${SITE_URL}/.well-known/mcp/server-card.json): ${MCP_ENDPOINT}, its tools and the scope each needs.`,
          `- [Agent skills](${SITE_URL}/.well-known/agent-skills/index.json): SKILL.md files for the local and remote MCP servers and the Screenshot API.`,
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

        const latest = (await fetchChangelog({ limit: 10 }))?.entries ?? [];
        lines.push(
          "",
          "## Changelog",
          `- [Changelog](${SITE_URL}${changelogMarkdownHref(CHANGELOG_PATH)}): ${CHANGELOG_DESCRIPTION} Newest first; RSS at ${SITE_URL}${CHANGELOG_FEED_PATH}.`,
          ...latest.map(
            (e) => `- [${e.title}](${SITE_URL}${changelogMarkdownHref(changelogEntryPath(e.slug))}): ${e.summary} (${e.publishedAt.slice(0, 10)})`
          )
        );

        lines.push(
          "",
          "## Agents",
          `- [Everything in one file](${SITE_URL}/llms-full.txt): Every page on this site as Markdown, in a single fetch.`,
          `- [Agents & MCP](${SITE_URL}${markdownHref("/agents")}): How to connect Claude, ChatGPT, Cursor, Copilot, and Windsurf to CaptureCat's MCP server on the Mac.`,
          `- [Connect any agent](${SITE_URL}${markdownHref("/agents")}): The remote MCP server at ${MCP_ENDPOINT} for cloud agents: Claude.ai and ChatGPT connectors sign in with OAuth, other clients use a scoped token from Settings → Agent access.`,
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
