import { Link, createFileRoute, notFound } from "@tanstack/react-router";
import { ArrowLeft, ArrowRight, Github } from "lucide-react";

import { DocBlocks, Inline } from "@/components/docs/DocBlocks";
import { DocsShell } from "@/components/docs/DocsShell";
import { PseoCta } from "@/components/marketing/PseoSections";
import {
  availabilityLine,
  docJsonLd,
  docNavTitle,
  docPath,
  findDoc,
  headingId,
  prevNext,
  relatedDocs,
  type DocBlock,
} from "@/lib/docs";
import { jsonLd } from "@/lib/json-ld";
import { pageHead } from "@/lib/site-content";

/**
 * /docs/{section}/{page}: one documentation page. Content, Markdown twin and
 * JSON-LD all come from the record in lib/docs/sections/*.ts.
 */
export const Route = createFileRoute("/docs/$")({
  loader: ({ params }) => {
    const doc = findDoc(params._splat ?? "");
    if (!doc) throw notFound();
    return { slug: doc.page.slug };
  },
  head: ({ params }) => {
    const doc = findDoc(params._splat ?? "");
    return doc ? pageHead(docPath(doc.page)) : {};
  },
  component: DocPageView,
});

const REPO_FILE = "https://github.com/capturecat-dev/capturecat/blob/main/apps/web/src/lib/docs/sections";

function DocPageView() {
  const { slug } = Route.useLoaderData();
  const { page, section } = findDoc(slug)!;
  const { prev, next } = prevNext(page.slug);
  const related = relatedDocs(page);
  const availability = availabilityLine(page);
  const toc = page.blocks
    .filter((b): b is Extract<DocBlock, { type: "h2" }> => b.type === "h2")
    .map((b) => ({ id: headingId(b), text: b.text }));
  if (page.faqs?.length) toc.push({ id: "faq", text: "FAQ" });

  return (
    <DocsShell activeSlug={page.slug} toc={toc}>
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLd(docJsonLd({ page, section })) }} />
      <article className="max-w-3xl">
        <p className="text-[12px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">{section.title}</p>
        <h1 className="mt-3 text-balance text-4xl font-semibold leading-[1.1] tracking-[-0.03em] md:text-[2.75rem]">
          {page.title}
        </h1>
        {availability && (
          <p className="mt-4 inline-flex items-center rounded-full border border-white/12 bg-white/[0.05] px-3 py-1 text-xs text-muted-foreground">
            {availability}
          </p>
        )}
        <p className="mt-6 text-pretty text-lg leading-relaxed text-foreground/85">
          <Inline text={page.summary} />
        </p>

        <div className="mt-8">
          <DocBlocks blocks={page.blocks} />
        </div>

        {page.faqs && page.faqs.length > 0 && (
          <section className="mt-12">
            <h2 id="faq" className="scroll-mt-24 text-2xl font-semibold tracking-[-0.02em]">
              FAQ
            </h2>
            <dl className="mt-5 divide-y divide-white/8 rounded-2xl border border-white/10 bg-white/[0.035]">
              {page.faqs.map((f) => (
                <div key={f.question} className="p-5">
                  <dt className="font-medium">{f.question}</dt>
                  <dd className="mt-2 text-[14.5px] leading-relaxed text-muted-foreground">
                    <Inline text={f.answer} />
                  </dd>
                </div>
              ))}
            </dl>
          </section>
        )}

        {related.length > 0 && (
          <section className="mt-12">
            <h2 className="text-lg font-semibold tracking-[-0.01em]">Related</h2>
            <ul className="mt-3 space-y-2">
              {related.map((r) => (
                <li key={r.slug}>
                  <Link
                    to="/docs/$"
                    params={{ _splat: r.slug }}
                    className="text-[15px] text-muted-foreground underline decoration-white/20 underline-offset-4 transition-colors hover:text-foreground"
                  >
                    {r.title}
                  </Link>
                </li>
              ))}
            </ul>
          </section>
        )}

        <nav aria-label="Previous and next" className="mt-14 grid grid-cols-1 gap-3 sm:grid-cols-2">
          {prev ? (
            <Link
              to="/docs/$"
              params={{ _splat: prev.slug }}
              className="group rounded-2xl border border-white/10 bg-white/[0.035] p-4 transition-colors hover:bg-white/[0.07]"
            >
              <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
                <ArrowLeft className="size-3.5" /> Previous
              </span>
              <span className="mt-1 block font-medium">{docNavTitle(prev)}</span>
            </Link>
          ) : (
            <span />
          )}
          {next && (
            <Link
              to="/docs/$"
              params={{ _splat: next.slug }}
              className="group rounded-2xl border border-white/10 bg-white/[0.035] p-4 text-right transition-colors hover:bg-white/[0.07]"
            >
              <span className="flex items-center justify-end gap-1.5 text-xs text-muted-foreground">
                Next <ArrowRight className="size-3.5" />
              </span>
              <span className="mt-1 block font-medium">{docNavTitle(next)}</span>
            </Link>
          )}
        </nav>

        <p className="mt-8 flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-muted-foreground">
          <span>Last checked {page.lastModified}</span>
          <a
            href={`${REPO_FILE}/${section.id}.ts`}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1.5 transition-colors hover:text-foreground"
          >
            <Github className="size-3.5" /> Edit this page on GitHub
          </a>
          <a href={`${docPath(page)}.md`} className="transition-colors hover:text-foreground">
            View as Markdown
          </a>
        </p>
      </article>
      <div className="mt-16 -mx-4 sm:-mx-6">
        <PseoCta />
      </div>
    </DocsShell>
  );
}
