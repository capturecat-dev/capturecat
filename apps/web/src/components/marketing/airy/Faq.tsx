import { useState, type ReactNode } from "react";
import { ChevronDown } from "lucide-react";

import { HOME_FAQ } from "../home/Faq";
import { AirContainer, AirTitle } from "./primitives";

/**
 * The light pages' FAQ: one white surface, hairline rows, one open at a
 * time. Its own module so pages without the home's demos (the pSEO pages,
 * and docs through PseoSections) don't pull them in.
 */
export function AirFaq({
  items = HOME_FAQ,
  title = "Questions, answered.",
}: {
  items?: ReadonlyArray<{ q: string; a: string }>;
  title?: ReactNode;
}) {
  const [open, setOpen] = useState<number | null>(0);
  return (
    <section className="bg-[var(--cc-air-tint)] py-24 md:py-32">
      <AirContainer className="max-w-3xl">
        <AirTitle className="scroll-reveal text-center">{title}</AirTitle>
        <div className="mt-12 divide-y divide-[var(--cc-air-hairline)] overflow-hidden rounded-[24px] bg-white ring-1 ring-black/[0.06]">
          {items.map((item, i) => {
            const isOpen = open === i;
            return (
              <div key={item.q}>
                <button
                  type="button"
                  aria-expanded={isOpen}
                  onClick={() => setOpen(isOpen ? null : i)}
                  className="flex w-full items-center justify-between gap-6 px-6 py-5 text-left text-[16px] font-medium text-[var(--cc-air-ink)] md:px-7"
                >
                  {item.q}
                  <ChevronDown
                    className={`h-5 w-5 shrink-0 text-[var(--cc-air-faint)] transition-transform duration-300 ${
                      isOpen ? "rotate-180" : ""
                    }`}
                  />
                </button>
                <div
                  className={`grid transition-[grid-template-rows] duration-300 ease-[cubic-bezier(0.22,1,0.36,1)] ${
                    isOpen ? "grid-rows-[1fr]" : "grid-rows-[0fr]"
                  }`}
                >
                  <div className="overflow-hidden">
                    <p className="px-6 pb-6 text-[15px] leading-relaxed text-[var(--cc-air-muted)] md:px-7">{item.a}</p>
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </AirContainer>
    </section>
  );
}
