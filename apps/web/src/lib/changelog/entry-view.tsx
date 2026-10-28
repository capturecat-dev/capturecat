/**
 * One changelog entry as the public site shows it: date and version, the
 * category and platform badges, the title, the one-line summary and the
 * rendered Markdown body.
 *
 * Shared on purpose: capturecat.so/changelog and /changelog/<slug> render
 * entries with this component, and the admin console's editor renders its
 * live preview with it too (apps/admin imports this file by relative path),
 * so what the owner previews is what readers get. Router-agnostic — the page
 * passes `renderTitle` to make the title a link. No `@/` imports.
 */
import type { ReactNode } from "react";

import { ChangelogMarkdown } from "./markdown";
import { CATEGORY_META, PLATFORM_LABELS, formatChangelogDate, versionLabel, type ChangelogEntry } from "./model";

export type ChangelogEntryLike = Pick<ChangelogEntry, "title" | "summary" | "body" | "category" | "platforms" | "version"> & {
  /** null = not published (the admin preview of a draft). */
  publishedAt: string | null;
};

const pill = "inline-flex h-6 items-center rounded-full border px-2.5 text-[12px] font-medium leading-none";

export function ChangelogBadges({ entry }: { entry: Pick<ChangelogEntryLike, "category" | "platforms"> }) {
  const category = CATEGORY_META[entry.category] ?? CATEGORY_META.new;
  return (
    <div className="flex flex-wrap items-center gap-1.5">
      <span className={`${pill} ${category.badge}`}>{category.label}</span>
      {entry.platforms.map((p) => (
        <span key={p} className={`${pill} border-white/12 bg-white/[0.05] text-muted-foreground`}>
          {PLATFORM_LABELS[p] ?? p}
        </span>
      ))}
    </div>
  );
}

export function ChangelogEntryView({
  entry,
  variant = "list",
  renderTitle,
  className = "",
}: {
  entry: ChangelogEntryLike;
  /** "list": an h3 under a month heading. "page": the entry's own page (h1). */
  variant?: "list" | "page";
  /** Wraps the title text, e.g. in a router Link to the entry's page. */
  renderTitle?: (title: ReactNode) => ReactNode;
  className?: string;
}) {
  const page = variant === "page";
  const Title = page ? "h1" : "h3";
  const title = renderTitle ? renderTitle(entry.title) : entry.title;
  return (
    <article className={className}>
      <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
        <p className="flex flex-wrap items-center gap-x-2 text-[13px] text-muted-foreground">
          {entry.publishedAt ? (
            <time dateTime={entry.publishedAt}>{formatChangelogDate(entry.publishedAt)}</time>
          ) : (
            <span>Not published</span>
          )}
          {entry.version && (
            <>
              <span aria-hidden className="text-white/25">
                ·
              </span>
              <span className="font-mono text-[12.5px] text-foreground/80">{versionLabel(entry.version)}</span>
            </>
          )}
        </p>
        <ChangelogBadges entry={entry} />
      </div>
      <Title
        className={
          page
            ? "mt-5 text-balance text-4xl font-semibold leading-[1.1] tracking-[-0.03em] text-foreground md:text-[2.75rem]"
            : "mt-3 text-balance text-2xl font-semibold leading-tight tracking-[-0.02em] text-foreground"
        }
      >
        {title}
      </Title>
      {entry.summary && (
        <p className={`text-pretty leading-relaxed text-foreground/85 ${page ? "mt-5 text-lg" : "mt-3 text-[16px]"}`}>
          {entry.summary}
        </p>
      )}
      <ChangelogMarkdown source={entry.body} headingBase={page ? 2 : 4} className={page ? "mt-8" : "mt-5"} />
    </article>
  );
}
