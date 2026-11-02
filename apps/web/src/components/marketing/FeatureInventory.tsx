import { FEATURE_GROUPS } from "@/lib/feature-inventory";
import { AIR_CARD, AirContainer, AirTitle } from "./airy/primitives";

/**
 * The complete inventory, every shipped feature grouped. Data lives in
 * lib/feature-inventory.ts and also renders the Markdown twin of the home
 * page, so this list and /index.md never drift.
 */
export default function FeatureInventory({
  title = "Everything in the box.",
  muted = "The full list, nothing on it that the app does not do today.",
}: {
  title?: string;
  muted?: string;
}) {
  return (
    <section id="everything" className="relative scroll-mt-24 bg-[var(--cc-air-tint)] py-24 md:py-32">
      <AirContainer>
        <AirTitle className="scroll-reveal max-w-2xl" muted={muted}>
          {title}
        </AirTitle>
        <div className="mt-14 columns-1 gap-4 md:columns-2 lg:columns-3">
          {FEATURE_GROUPS.map((group) => (
            <article key={group.title} className={`${AIR_CARD} scroll-reveal mb-4 break-inside-avoid p-7`}>
              <h3 className="text-[16px] font-semibold tracking-[-0.01em] text-[var(--cc-air-ink)]">
                {group.title}
              </h3>
              <ul className="mt-4 space-y-2.5">
                {group.items.map((item) => (
                  <li key={item} className="flex gap-2.5 text-[14px] leading-relaxed text-[var(--cc-air-muted)]">
                    <span aria-hidden className="mt-[9px] h-1 w-1 shrink-0 rounded-full bg-[var(--cc-air-violet)]" />
                    {item}
                  </li>
                ))}
              </ul>
            </article>
          ))}
        </div>
      </AirContainer>
    </section>
  );
}
