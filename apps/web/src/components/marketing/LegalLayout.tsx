import type { ReactNode } from "react";

import Navbar from "./Navbar";
import Footer from "./Footer";
import { Ambient, Container, Eyebrow } from "./primitives";

export interface LegalSection {
  id: string;
  label: string;
}

/**
 * Privacy and Terms: the site's glass typography and layout, no motion.
 * One stacked glass surface with hairline-divided sections (no card grid),
 * and a sticky contents list on wide screens.
 */
export function LegalLayout({
  title,
  updated,
  sections,
  children,
}: {
  title: string;
  updated: string;
  sections: LegalSection[];
  children: ReactNode;
}) {
  return (
    <main className="flex min-h-screen flex-col bg-background">
      <Navbar />
      <section className="relative isolate overflow-hidden">
        <Ambient variant="top" />
        <Container className="pb-10 pt-16 md:pt-24">
          <Eyebrow>Legal</Eyebrow>
          <h1 className="mt-6 max-w-3xl text-balance text-4xl font-semibold leading-[1.05] tracking-[-0.03em] text-foreground md:text-6xl">
            {title}
          </h1>
          <p className="mt-4 text-sm text-muted-foreground">Last updated: {updated}</p>
        </Container>
      </section>

      <Container className="flex-1 pb-28">
        <div className="grid grid-cols-1 gap-10 lg:grid-cols-12">
          <nav aria-label="Contents" className="hidden lg:col-span-3 lg:block">
            <div className="sticky top-24">
              <p className="text-[12px] font-medium uppercase tracking-[0.08em] text-muted-foreground">Contents</p>
              <ol className="mt-4 space-y-1 border-l border-white/10">
                {sections.map((s) => (
                  <li key={s.id}>
                    <a
                      href={`#${s.id}`}
                      className="-ml-px block border-l border-transparent py-1.5 pl-4 text-[13.5px] leading-snug text-muted-foreground transition-colors hover:border-white/40 hover:text-foreground focus-visible:border-white/60 focus-visible:text-foreground focus-visible:outline-none"
                    >
                      {s.label}
                    </a>
                  </li>
                ))}
              </ol>
            </div>
          </nav>

          <article className="relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.035] px-6 py-8 md:px-10 md:py-10 lg:col-span-9">
            <span
              aria-hidden
              className="absolute inset-x-10 top-0 h-px bg-gradient-to-r from-transparent via-white/35 to-transparent"
            />
            <div className="max-w-2xl text-[15.5px] leading-[1.75] text-muted-foreground [&>section+section]:mt-9 [&>section+section]:border-t [&>section+section]:border-white/8 [&>section+section]:pt-9 [&_a]:text-foreground [&_a]:underline [&_a]:decoration-white/30 [&_a]:underline-offset-4 [&_a:hover]:decoration-white/70 [&_h2]:scroll-mt-28 [&_h2]:text-[22px] [&_h2]:font-medium [&_h2]:tracking-[-0.02em] [&_h2]:text-foreground [&_h3]:mt-5 [&_h3]:text-[16px] [&_h3]:font-medium [&_h3]:text-foreground [&_li]:pl-1 [&_ul]:list-disc [&_ul]:space-y-2 [&_ul]:pl-5 [&_ul]:marker:text-cyan-300/60">
              {children}
            </div>
          </article>
        </div>
      </Container>
      <Footer />
    </main>
  );
}
