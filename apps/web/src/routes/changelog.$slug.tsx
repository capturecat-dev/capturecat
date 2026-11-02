import { Link, createFileRoute, notFound } from "@tanstack/react-router";

import { AirPage, BackPill } from "@/components/marketing/airy/Page";
import { AirCard } from "@/components/marketing/airy/primitives";
import airyCss from "@/styles/airy.css?url";
import { ChangelogEntryView } from "@/lib/changelog/entry-view";
import type { ChangelogEntry } from "@/lib/changelog/model";
import {
  CHANGELOG_FEED_PATH,
  changelogEntryPath,
  changelogHead,
  changelogMarkdownHref,
  fetchChangelogEntry,
} from "@/lib/changelog/site";
import { ORGANIZATION_JSON_LD, jsonLd } from "@/lib/json-ld";
import { SITE_URL } from "@/lib/site-content";

/**
 * /changelog/{slug}: one published entry (GET /api/changelog/:slug). A
 * draft, a scheduled entry and an unknown slug are the same 404.
 */
export const Route = createFileRoute("/changelog/$slug")({
  loader: async ({ params }) => {
    const entry = await fetchChangelogEntry(params.slug);
    if (entry === null) throw notFound();
    return { entry: entry === "error" ? null : entry, slug: params.slug };
  },
  head: ({ loaderData }) => {
    const entry = loaderData?.entry;
    const airy = { rel: "stylesheet", href: airyCss };
    if (!entry)
      return { meta: [{ title: "Changelog | CaptureCat" }, { name: "robots", content: "noindex" }], links: [airy] };
    const head = changelogHead({
      path: changelogEntryPath(entry.slug),
      title: entry.title.length + 13 <= 65 ? `${entry.title} | CaptureCat` : entry.title,
      description: entry.summary,
      ogType: "article",
      publishedAt: entry.publishedAt,
      modifiedAt: entry.updatedAt,
    });
    return { ...head, links: [...head.links, airy] };
  },
  component: ChangelogEntryPage,
});

function entryJsonLd(entry: ChangelogEntry) {
  const url = `${SITE_URL}${changelogEntryPath(entry.slug)}`;
  return {
    "@context": "https://schema.org",
    "@type": "BlogPosting",
    headline: entry.title,
    description: entry.summary,
    datePublished: entry.publishedAt,
    dateModified: entry.updatedAt > entry.publishedAt ? entry.updatedAt : entry.publishedAt,
    url,
    mainEntityOfPage: url,
    author: { "@id": ORGANIZATION_JSON_LD["@id"] },
    publisher: ORGANIZATION_JSON_LD,
    isPartOf: { "@type": "CollectionPage", name: "CaptureCat changelog", url: `${SITE_URL}/changelog` },
  };
}

const footLink = "transition-colors hover:text-[var(--cc-air-ink)]";

function ChangelogEntryPage() {
  const { entry, slug } = Route.useLoaderData();

  return (
    <AirPage>
      {entry && <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLd(entryJsonLd(entry)) }} />}

      <section className="relative isolate -mt-[68px] overflow-hidden">
        <div className="air-wash !bottom-auto h-[460px]" aria-hidden />
        <div className="mx-auto w-full max-w-3xl px-6 pb-24 pt-[124px] md:pt-[156px]">
          <BackPill to="/changelog">Changelog</BackPill>

          {entry ? (
            <AirCard as="article" className="mt-8 px-6 py-8 md:px-10 md:py-10">
              <ChangelogEntryView entry={entry} variant="page" tone="light" />
            </AirCard>
          ) : (
            <div className="mt-8">
              <h1 className="text-3xl font-semibold tracking-[-0.02em] text-[var(--cc-air-ink)]">
                This update couldn&rsquo;t load just now
              </h1>
              <p className="mt-3 text-[var(--cc-air-muted)]">Try again in a minute.</p>
            </div>
          )}

          <p className="mt-12 flex flex-wrap items-center gap-x-4 gap-y-2 border-t border-[var(--cc-air-hairline)] pt-6 text-xs text-[var(--cc-air-muted)]">
            <Link to="/changelog" className={footLink}>
              All updates
            </Link>
            <a href={changelogMarkdownHref(changelogEntryPath(slug))} className={footLink}>
              View as Markdown
            </a>
            <a href={CHANGELOG_FEED_PATH} className={footLink}>
              RSS feed
            </a>
          </p>
        </div>
      </section>
    </AirPage>
  );
}
