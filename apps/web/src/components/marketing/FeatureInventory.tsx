import { FEATURE_GROUPS } from "@/lib/feature-inventory";
import { Container, GlassCard, SectionTitle } from "./primitives";

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
    <section id="everything" className="relative isolate py-24">
      <Container>
        <SectionTitle className="scroll-reveal" muted={muted}>
          {title}
        </SectionTitle>
        <div className="mt-12 columns-1 gap-4 md:columns-2 lg:columns-3">
          {FEATURE_GROUPS.map((group) => (
            <GlassCard
              key={group.title}
              padding="p-7"
              className="scroll-reveal mb-4 break-inside-avoid"
            >
              <h3 className="text-base font-medium tracking-[-0.01em] text-foreground">
                {group.title}
              </h3>
              <ul className="mt-4 space-y-2.5">
                {group.items.map((item) => (
                  <li
                    key={item}
                    className="flex gap-2.5 text-[13.5px] leading-relaxed text-muted-foreground"
                  >
                    <span
                      aria-hidden
                      className="mt-[7px] h-1 w-1 shrink-0 rounded-full bg-cyan-300/60"
                    />
                    {item}
                  </li>
                ))}
              </ul>
            </GlassCard>
          ))}
        </div>
      </Container>
    </section>
  );
}
