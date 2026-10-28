import { Link, createFileRoute, notFound } from "@tanstack/react-router";
import { ArrowLeft } from "lucide-react";

import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import { Ambient } from "@/components/marketing/primitives";
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
    if (!entry) return { meta: [{ title: "Changelog | CaptureCat" }, { name: "robots", content: "noindex" }] };
    return changelogHead({
      path: changelogEntryPath(entry.slug),
      title: entry.title.length + 13 <= 65 ? `${entry.title} | CaptureCat` : entry.title,
      description: entry.summary,
      ogType: "article",
      publishedAt: entry.publishedAt,
      modifiedAt: entry.updatedAt,
    });
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

const footLink = "transition-colors hover:text-foreground";

function ChangelogEntryPage() {
  const { entry, slug } = Route.useLoaderData();

  return (
    <main className="flex min-h-screen flex-col bg-background">
      {entry && <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLd(entryJsonLd(entry)) }} />}
      <Navbar />

      <section className="relative isolate overflow-hidden">
        <Ambient variant="top" />
        <div className="mx-auto w-full max-w-3xl px-6 pb-24 pt-14 md:pt-20">
          <Link
            to="/changelog"
            className="inline-flex items-center gap-1.5 text-sm text-muted-foreground transition-colors hover:text-foreground"
          >
            <ArrowLeft className="h-4 w-4" /> Changelog
          </Link>

          {entry ? (
            <ChangelogEntryView entry={entry} variant="page" className="mt-8" />
          ) : (
            <div className="mt-8">
              <h1 className="text-3xl font-semibold tracking-[-0.02em]">This update couldn&rsquo;t load just now</h1>
              <p className="mt-3 text-muted-foreground">Try again in a minute.</p>
            </div>
          )}

          <p className="mt-16 flex flex-wrap items-center gap-x-4 gap-y-2 border-t border-white/8 pt-6 text-xs text-muted-foreground">
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

      <Footer />
    </main>
  );
}
