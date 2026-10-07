import { Link, createFileRoute } from "@tanstack/react-router";

import { DocsShell } from "@/components/docs/DocsShell";
import { DOC_SECTIONS, docNavTitle, docsHubJsonLd } from "@/lib/docs";
import { jsonLd } from "@/lib/json-ld";
import { pageHead } from "@/lib/site-content";

/** /docs: every section and page, from lib/docs. */
export const Route = createFileRoute("/docs/")({
  head: () => pageHead("/docs"),
  component: DocsHome,
});

function DocsHome() {
  return (
    <DocsShell>
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLd(docsHubJsonLd()) }} />
      <div className="max-w-4xl">
        <p className="text-[12px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">Documentation</p>
        <h1 className="mt-3 text-balance text-4xl font-semibold leading-[1.08] tracking-[-0.03em] md:text-5xl">
          Everything CaptureCat does, and how to do it.
        </h1>
        <p className="mt-5 max-w-2xl text-pretty text-lg leading-relaxed text-muted-foreground">
          Recording, editing, exporting and sharing on the Mac and in the browser, plus Pro features, AI agents, and
          running the open-source backend yourself.
        </p>

        <div className="mt-12 divide-y divide-white/8 overflow-hidden rounded-3xl border border-white/10 bg-white/[0.035] backdrop-blur-2xl">
          {DOC_SECTIONS.map((section) => (
            <section key={section.id} className="grid grid-cols-1 gap-4 p-6 md:grid-cols-[220px_minmax(0,1fr)] md:p-7">
              <div>
                <h2 className="text-lg font-semibold tracking-[-0.01em]">
                  <Link to="/docs/$" params={{ _splat: section.pages[0].slug }} className="hover:underline">
                    {section.title}
                  </Link>
                </h2>
                <p className="mt-1.5 text-sm leading-relaxed text-muted-foreground">{section.description}</p>
              </div>
              <ul className="grid grid-cols-1 gap-x-6 gap-y-2 sm:grid-cols-2">
                {section.pages.map((page) => (
                  <li key={page.slug}>
                    <Link
                      to="/docs/$"
                      params={{ _splat: page.slug }}
                      className="text-[15px] text-muted-foreground transition-colors hover:text-foreground"
                    >
                      {docNavTitle(page)}
                    </Link>
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      </div>
    </DocsShell>
  );
}
