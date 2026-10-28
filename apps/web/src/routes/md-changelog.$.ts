import { createFileRoute } from "@tanstack/react-router";

import { changelogEntryMarkdown, changelogMarkdown } from "@/lib/changelog/feeds";
import {
  CHANGELOG_DESCRIPTION,
  CHANGELOG_PATH,
  changelogEntryPath,
  fetchAllChangelog,
  fetchChangelogEntry,
} from "@/lib/changelog/site";
import { SITE_URL, canonicalUrl } from "@/lib/site-content";

/**
 * Markdown twins of the changelog, at the internal /md-changelog/* paths:
 * /changelog.md → /md-changelog, /changelog/<slug>.md → /md-changelog/<slug>
 * (rewritten in src/server.ts, which also sends agents that ask for
 * text/markdown here). Same headers as the registry twins
 * (lib/markdown-pages.ts): canonical → the HTML page, which is what search
 * engines should index.
 */
const SITE = { siteUrl: SITE_URL, title: "CaptureCat changelog", description: CHANGELOG_DESCRIPTION };

function markdown(body: string, path: string, status = 200): Response {
  const canonical = canonicalUrl(path);
  return new Response(`<!-- canonical: ${canonical} -->\n\n${body}`, {
    status,
    headers: {
      "Content-Type": "text/markdown; charset=utf-8",
      "Cache-Control": status === 200 ? "public, max-age=120, s-maxage=300" : "no-store",
      Link: `<${canonical}>; rel="canonical"`,
      "X-Robots-Tag": "all",
    },
  });
}

const notFoundMd = () =>
  new Response("# Not found\n\nNo published changelog entry at this address.\n", {
    status: 404,
    headers: { "Content-Type": "text/markdown; charset=utf-8" },
  });

export const Route = createFileRoute("/md-changelog/$")({
  server: {
    handlers: {
      GET: async ({ params }) => {
        const slug = (params as { _splat?: string })._splat ?? "";
        if (slug === "") {
          const entries = await fetchAllChangelog(200);
          if (!entries) return markdown("# CaptureCat changelog\n\nTemporarily unavailable. Try again in a minute.\n", CHANGELOG_PATH, 503);
          return markdown(changelogMarkdown(entries, SITE), CHANGELOG_PATH);
        }
        const entry = await fetchChangelogEntry(slug);
        if (entry === null) return notFoundMd();
        if (entry === "error") return markdown("# Temporarily unavailable\n\nTry again in a minute.\n", changelogEntryPath(slug), 503);
        return markdown(changelogEntryMarkdown(entry, SITE), changelogEntryPath(entry.slug));
      },
    },
  },
});
