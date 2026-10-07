import type { ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ChevronDown } from "lucide-react";

import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import { DOC_SECTIONS, docNavTitle } from "@/lib/docs";
import { cn } from "@/lib/utils";

/**
 * The /docs frame: marketing navbar and footer around a sidebar of every
 * section (collapsible on phones), the article, and an optional
 * on-this-page rail on wide screens.
 */

function Sidebar({ activeSlug }: { activeSlug?: string }) {
  return (
    <nav aria-label="Documentation" className="space-y-6 text-[14px]">
      <Link
        to="/docs"
        className={cn(
          "block font-medium transition-colors hover:text-foreground",
          activeSlug === undefined ? "text-foreground" : "text-muted-foreground"
        )}
      >
        Docs home
      </Link>
      {DOC_SECTIONS.map((section) => (
        <div key={section.id}>
          <p className="mb-2 text-[11px] font-semibold uppercase tracking-[0.14em] text-muted-foreground/80">
            {section.title}
          </p>
          <ul className="space-y-0.5 border-l border-white/8">
            {section.pages.map((page) => {
              const active = page.slug === activeSlug;
              return (
                <li key={page.slug}>
                  <Link
                    to="/docs/$"
                    params={{ _splat: page.slug }}
                    aria-current={active ? "page" : undefined}
                    className={cn(
                      "-ml-px block border-l py-1.5 pl-3 leading-snug transition-colors",
                      active
                        ? "border-cyan-300/80 font-medium text-foreground"
                        : "border-transparent text-muted-foreground hover:border-white/30 hover:text-foreground"
                    )}
                  >
                    {docNavTitle(page)}
                  </Link>
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </nav>
  );
}

export function DocsShell({
  activeSlug,
  toc,
  children,
}: {
  activeSlug?: string;
  toc?: Array<{ id: string; text: string }>;
  children: ReactNode;
}) {
  return (
    <main className="flex min-h-screen flex-col bg-background">
      <Navbar />
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[520px]"
        style={{
          background:
            "radial-gradient(90% 70% at 50% -20%, rgba(120,140,255,0.14), transparent 60%)," +
            "radial-gradient(60% 50% at 90% 10%, rgba(80,220,255,0.07), transparent 55%)",
        }}
      />
      <div className="mx-auto grid w-full max-w-7xl flex-1 grid-cols-1 gap-10 px-4 pb-20 pt-24 sm:px-6 md:pt-28 lg:grid-cols-[230px_minmax(0,1fr)] xl:grid-cols-[230px_minmax(0,1fr)_200px]">
        <aside className="lg:sticky lg:top-24 lg:max-h-[calc(100vh-7rem)] lg:overflow-y-auto lg:pb-10 lg:pr-2">
          <details className="group rounded-2xl border border-white/10 bg-white/[0.04] p-4 lg:hidden">
            <summary className="flex cursor-pointer list-none items-center justify-between text-sm font-medium">
              Browse docs
              <ChevronDown className="size-4 transition-transform group-open:rotate-180" />
            </summary>
            <div className="mt-4">
              <Sidebar activeSlug={activeSlug} />
            </div>
          </details>
          <div className="hidden lg:block">
            <Sidebar activeSlug={activeSlug} />
          </div>
        </aside>

        <div className="min-w-0">{children}</div>

        {toc && toc.length > 1 && (
          <aside className="hidden xl:block">
            <div className="sticky top-24">
              <p className="mb-3 text-[11px] font-semibold uppercase tracking-[0.14em] text-muted-foreground/80">
                On this page
              </p>
              <ul className="space-y-2 text-[13px]">
                {toc.map((t) => (
                  <li key={t.id}>
                    <a href={`#${t.id}`} className="text-muted-foreground transition-colors hover:text-foreground">
                      {t.text}
                    </a>
                  </li>
                ))}
              </ul>
            </div>
          </aside>
        )}
      </div>
      <Footer />
    </main>
  );
}
