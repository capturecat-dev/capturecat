import type { ReactNode } from "react";
import { Building2, Scale } from "lucide-react";

import { AirPage, AirPageHero } from "./airy/Page";
import { AIR_CARD, AirContainer } from "./airy/primitives";

export interface LegalSection {
  id: string;
  label: string;
}

/**
 * Privacy, Terms, About and Contact: the light pages' type and layout, no
 * motion. One white surface with hairline-divided sections (no card grid),
 * and a sticky contents list on wide screens. Routes add styles/airy.css.
 */
export function LegalLayout({
  title,
  updated,
  sections,
  eyebrow = "Legal",
  children,
}: {
  title: string;
  updated: string;
  sections: LegalSection[];
  /** The label above the title: "Legal" for the policies, "Company" for About/Contact. */
  eyebrow?: string;
  children: ReactNode;
}) {
  return (
    <AirPage>
      <AirPageHero
        align="left"
        pill={eyebrow}
        icon={
          eyebrow === "Legal" ? (
            <Scale className="h-3.5 w-3.5" strokeWidth={2} />
          ) : (
            <Building2 className="h-3.5 w-3.5" strokeWidth={2} />
          )
        }
        title={title}
        className="md:!pb-14"
      >
        <p className="mt-4 text-[13.5px] text-[var(--cc-air-faint)]">Last updated: {updated}</p>
      </AirPageHero>

      <AirContainer className="flex-1 pb-28">
        <div className="grid grid-cols-1 gap-10 lg:grid-cols-12">
          <nav aria-label="Contents" className="hidden lg:col-span-3 lg:block">
            <div className="sticky top-24">
              <p className="text-[12px] font-medium uppercase tracking-[0.08em] text-[var(--cc-air-faint)]">Contents</p>
              <ol className="mt-4 space-y-1 border-l border-[var(--cc-air-hairline)]">
                {sections.map((s) => (
                  <li key={s.id}>
                    <a
                      href={`#${s.id}`}
                      className="-ml-px block border-l border-transparent py-1.5 pl-4 text-[13.5px] leading-snug text-[var(--cc-air-muted)] transition-colors hover:border-[var(--cc-air-ink)] hover:text-[var(--cc-air-ink)] focus-visible:border-[var(--cc-air-ink)] focus-visible:text-[var(--cc-air-ink)] focus-visible:outline-none"
                    >
                      {s.label}
                    </a>
                  </li>
                ))}
              </ol>
            </div>
          </nav>

          <article className={`${AIR_CARD} px-6 py-8 md:px-10 md:py-10 lg:col-span-9`}>
            <div className="max-w-2xl text-[15.5px] leading-[1.75] text-[var(--cc-air-muted)] [&>section+section]:mt-9 [&>section+section]:border-t [&>section+section]:border-[var(--cc-air-hairline)] [&>section+section]:pt-9 [&_a]:font-medium [&_a]:text-[var(--cc-air-ink)] [&_a]:underline [&_a]:decoration-black/20 [&_a]:underline-offset-4 [&_a:hover]:decoration-black/60 [&_h2]:scroll-mt-28 [&_h2]:text-[22px] [&_h2]:font-semibold [&_h2]:tracking-[-0.02em] [&_h2]:text-[var(--cc-air-ink)] [&_h3]:mt-5 [&_h3]:text-[16px] [&_h3]:font-semibold [&_h3]:text-[var(--cc-air-ink)] [&_li]:pl-1 [&_ul]:list-disc [&_ul]:space-y-2 [&_ul]:pl-5 [&_ul]:marker:text-[var(--cc-air-violet)]">
              {children}
            </div>
          </article>
        </div>
      </AirContainer>
    </AirPage>
  );
}
