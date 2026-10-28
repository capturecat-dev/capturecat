import type { ReactNode } from "react";
import { Link, createFileRoute } from "@tanstack/react-router";
import { FileText, Rss } from "lucide-react";

import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import { Ambient, Container, Eyebrow, IconTile } from "@/components/marketing/primitives";
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
  head: ({ loaderData }) =>
    changelogHead({
      path: CHANGELOG_PATH,
      title: CHANGELOG_SEO_TITLE,
      description: CHANGELOG_DESCRIPTION,
      noindex: !!loaderData?.cursor,
    }),
  component: ChangelogPage,
});

const smallPill =
  "inline-flex h-9 items-center gap-2 rounded-full border border-white/12 bg-white/[0.06] px-4 text-[13.5px] font-medium text-muted-foreground backdrop-blur-xl transition-colors hover:border-white/20 hover:bg-white/[0.10] hover:text-foreground";
const secondary =
  "inline-flex h-12 items-center justify-center gap-2 rounded-full border border-white/12 bg-white/[0.06] px-7 text-[15px] font-medium text-foreground backdrop-blur-xl transition-colors duration-300 hover:border-white/20 hover:bg-white/[0.10]";
const glass = "relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.035] backdrop-blur-2xl";

function Specular() {
  return (
    <span
      aria-hidden
      className="absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
    />
  );
}

function ChangelogPage() {
  const { page, cursor } = Route.useLoaderData();
  const groups = page ? groupByMonth(page.entries) : [];

  return (
    <main className="flex min-h-screen flex-col bg-background">
      <Navbar />

      <section className="relative isolate overflow-hidden">
        <Ambient variant="hero" />
        <Container className="flex flex-col items-center pb-14 pt-16 text-center md:pt-24">
          <Eyebrow>Changelog</Eyebrow>
          <h1 className="mt-6 max-w-3xl text-balance text-5xl font-semibold leading-[1.04] tracking-[-0.03em] md:text-6xl">
            What&rsquo;s new in CaptureCat
          </h1>
          <p className="mx-auto mt-6 max-w-xl text-pretty text-lg leading-relaxed text-muted-foreground">
            New features, improvements and fixes across the Mac app, the web
            app, the API and agents. Newest first.
          </p>
          <div className="mt-8 flex flex-wrap items-center justify-center gap-2">
            <a href={CHANGELOG_FEED_PATH} className={smallPill}>
              <Rss className="h-4 w-4" /> RSS feed
            </a>
            <a href={changelogMarkdownHref(CHANGELOG_PATH)} className={smallPill}>
              <FileText className="h-4 w-4" /> View as Markdown
            </a>
          </div>
        </Container>
      </section>

      <section className="relative isolate pb-24">
        <div className="mx-auto w-full max-w-3xl px-6">
          {!page ? (
            <Notice title="The changelog couldn't load just now">
              Something between this page and our API is having a moment. Try again in a minute, or follow the{" "}
              <a href={CHANGELOG_FEED_PATH} className="text-foreground underline decoration-white/25 underline-offset-4">
                RSS feed
              </a>
              .
            </Notice>
          ) : groups.length === 0 ? (
            cursor ? (
              <Notice title="No older updates">
                That&rsquo;s the beginning of the changelog.{" "}
                <Link to="/changelog" className="text-foreground underline decoration-white/25 underline-offset-4">
                  Back to the latest
                </Link>
                .
              </Notice>
            ) : (
              <Notice title="Nothing here yet">
                The first entry lands with the next release. Follow the{" "}
                <a href={CHANGELOG_FEED_PATH} className="text-foreground underline decoration-white/25 underline-offset-4">
                  RSS feed
                </a>{" "}
                to hear about it, or{" "}
                <Link to="/download" className="text-foreground underline decoration-white/25 underline-offset-4">
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
                    <h2 id={`month-${group.key}`} className="shrink-0 text-sm font-medium tracking-[-0.005em] text-foreground/90">
                      {group.label}
                    </h2>
                    <span aria-hidden className="h-px flex-1 bg-gradient-to-r from-white/15 to-transparent" />
                  </div>
                  <div className={`${glass} mt-4 divide-y divide-white/8`}>
                    <Specular />
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
              {cursor && (
                <Link to="/changelog" className={secondary}>
                  Latest updates
                </Link>
              )}
              {page.nextCursor && (
                <Link to="/changelog" search={{ cursor: page.nextCursor }} className={secondary}>
                  Older updates
                </Link>
              )}
            </nav>
          )}
        </div>
      </section>

      <Footer />
    </main>
  );
}

function EntryRow({ entry }: { entry: ChangelogEntry }) {
  return (
    <ChangelogEntryView
      entry={entry}
      className="scroll-mt-24 p-6 md:p-8"
      renderTitle={(title) => (
        <Link
          to="/changelog/$slug"
          params={{ slug: entry.slug }}
          className="decoration-white/30 underline-offset-[5px] transition-colors hover:underline"
        >
          {title}
        </Link>
      )}
    />
  );
}

function Notice({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className={`${glass} flex flex-col items-center px-6 py-14 text-center`}>
      <Specular />
      <IconTile>
        <Rss className="h-5 w-5" />
      </IconTile>
      <h2 className="mt-5 text-xl font-semibold tracking-[-0.01em]">{title}</h2>
      <p className="mt-2 max-w-md text-pretty text-[15px] leading-relaxed text-muted-foreground">{children}</p>
    </div>
  );
}
