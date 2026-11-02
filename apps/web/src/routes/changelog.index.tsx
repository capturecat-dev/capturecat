import type { ReactNode } from "react";
import { Link, createFileRoute } from "@tanstack/react-router";
import { FileText, Rss, Sparkles } from "lucide-react";

import { AirPage, AirPageHero } from "@/components/marketing/airy/Page";
import { AIR_CARD, AIR_CHIP, SoftLink } from "@/components/marketing/airy/primitives";
import airyCss from "@/styles/airy.css?url";
import { ChangelogEntryView } from "@/lib/changelog/entry-view";
import { groupByMonth, type ChangelogEntry } from "@/lib/changelog/model";
import {
  CHANGELOG_DESCRIPTION,
  CHANGELOG_FEED_PATH,
  CHANGELOG_PAGE_SIZE,
  CHANGELOG_PATH,
  CHANGELOG_SEO_TITLE,
  changelogHead,
  changelogMarkdownHref,
  fetchChangelog,
} from "@/lib/changelog/site";

/**
 * /changelog — every published entry, newest first, grouped by month.
 * Server-rendered from GET /api/changelog (the pricing page's loader
 * pattern); entries are written in the admin console. Older pages are
 * `?cursor=` links (keyset paging, so a new entry never shifts them).
 */
export const Route = createFileRoute("/changelog/")({
  validateSearch: (search: Record<string, unknown>): { cursor?: string } =>
    typeof search.cursor === "string" && search.cursor.length > 0 && search.cursor.length <= 200
      ? { cursor: search.cursor }
      : {},
  loaderDeps: ({ search }) => ({ cursor: search.cursor ?? null }),
  loader: async ({ deps }) => ({
    page: await fetchChangelog({ cursor: deps.cursor, limit: CHANGELOG_PAGE_SIZE }),
    cursor: deps.cursor,
  }),
  head: ({ loaderData }) => {
    const head = changelogHead({
      path: CHANGELOG_PATH,
      title: CHANGELOG_SEO_TITLE,
      description: CHANGELOG_DESCRIPTION,
      noindex: !!loaderData?.cursor,
    });
    return { ...head, links: [...head.links, { rel: "stylesheet", href: airyCss }] };
  },
  component: ChangelogPage,
});

const textLink = "font-medium text-[var(--cc-air-ink)] underline decoration-black/20 underline-offset-4 hover:decoration-black/60";

function ChangelogPage() {
  const { page, cursor } = Route.useLoaderData();
  const groups = page ? groupByMonth(page.entries) : [];

  return (
    <AirPage>
      <AirPageHero
        pill="Changelog"
        icon={<Sparkles className="h-3.5 w-3.5" strokeWidth={2} />}
        title="What’s new in CaptureCat"
        lede="New features, improvements and fixes across the Mac app, the web app, the API and agents. Newest first."
      >
        <div className="mt-8 flex flex-wrap items-center justify-center gap-2">
          <a href={CHANGELOG_FEED_PATH} className={`${AIR_CHIP} gap-2`}>
            <Rss className="h-4 w-4 text-[var(--cc-air-violet)]" /> RSS feed
          </a>
          <a href={changelogMarkdownHref(CHANGELOG_PATH)} className={`${AIR_CHIP} gap-2`}>
            <FileText className="h-4 w-4 text-[var(--cc-air-violet)]" /> View as Markdown
          </a>
        </div>
      </AirPageHero>

      <section className="relative isolate pb-24">
        <div className="mx-auto w-full max-w-3xl px-6">
          {!page ? (
            <Notice title="The changelog couldn't load just now">
              Something between this page and our API is having a moment. Try again in a minute, or follow the{" "}
              <a href={CHANGELOG_FEED_PATH} className={textLink}>
                RSS feed
              </a>
              .
            </Notice>
          ) : groups.length === 0 ? (
            cursor ? (
              <Notice title="No older updates">
                That&rsquo;s the beginning of the changelog.{" "}
                <Link to="/changelog" className={textLink}>
                  Back to the latest
                </Link>
                .
              </Notice>
            ) : (
              <Notice title="Nothing here yet">
                The first entry lands with the next release. Follow the{" "}
                <a href={CHANGELOG_FEED_PATH} className={textLink}>
                  RSS feed
                </a>{" "}
                to hear about it, or{" "}
                <Link to="/download" className={textLink}>
                  get the latest build
                </Link>
                .
              </Notice>
            )
          ) : (
            <div className="space-y-14">
              {groups.map((group) => (
                <section key={group.key} aria-labelledby={`month-${group.key}`}>
                  <div className="flex items-center gap-4">
                    <h2
                      id={`month-${group.key}`}
                      className="shrink-0 text-sm font-semibold tracking-[-0.005em] text-[var(--cc-air-ink)]"
                    >
                      {group.label}
                    </h2>
                    <span aria-hidden className="h-px flex-1 bg-[var(--cc-air-hairline)]" />
                  </div>
                  <div className={`${AIR_CARD} mt-4 divide-y divide-[var(--cc-air-hairline)] overflow-hidden`}>
                    {group.entries.map((entry) => (
                      <EntryRow key={entry.slug} entry={entry} />
                    ))}
                  </div>
                </section>
              ))}
            </div>
          )}

          {page && (page.nextCursor || cursor) && (
            <nav aria-label="More updates" className="mt-14 flex flex-wrap items-center justify-center gap-3">
              {cursor && <SoftLink to="/changelog">Latest updates</SoftLink>}
              {page.nextCursor && (
                <SoftLink to="/changelog" search={{ cursor: page.nextCursor }}>
                  Older updates
                </SoftLink>
              )}
            </nav>
          )}
        </div>
      </section>
    </AirPage>
  );
}

function EntryRow({ entry }: { entry: ChangelogEntry }) {
  return (
    <ChangelogEntryView
      entry={entry}
      tone="light"
      className="scroll-mt-24 p-6 md:p-8"
      renderTitle={(title) => (
        <Link
          to="/changelog/$slug"
          params={{ slug: entry.slug }}
          className="decoration-black/25 underline-offset-[5px] transition-colors hover:underline"
        >
          {title}
        </Link>
      )}
    />
  );
}

function Notice({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className={`${AIR_CARD} flex flex-col items-center px-6 py-14 text-center`}>
      <span className="inline-flex h-11 w-11 items-center justify-center rounded-2xl bg-[var(--cc-air-tint)] text-[var(--cc-air-violet)] ring-1 ring-black/[0.06]">
        <Rss className="h-5 w-5" />
      </span>
      <h2 className="mt-5 text-xl font-semibold tracking-[-0.01em] text-[var(--cc-air-ink)]">{title}</h2>
      <p className="mt-2 max-w-md text-pretty text-[15px] leading-relaxed text-[var(--cc-air-muted)]">{children}</p>
    </div>
  );
}
