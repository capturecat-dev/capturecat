import { MediaPlaceholder } from "../MediaPlaceholder";
import { Container, Eyebrow, Lede, SectionTitle } from "../primitives";

/**
 * Two identical recordings side by side: one raw, one exported from
 * CaptureCat. The point is that nobody touched the timeline in between.
 */
export default function BeforeAfter() {
  return (
    <section className="relative isolate py-24">
      <Container>
        <div className="scroll-reveal flex flex-col items-start gap-4">
          <Eyebrow>Same recording, no manual edits</Eyebrow>
          <SectionTitle muted="The one on the right took no extra time.">
            Here is what the auto edit actually does.
          </SectionTitle>
          <Lede>
            Both clips are the same twelve seconds of screen. The left one is
            what QuickTime gives you. The right one is what CaptureCat exported
            the moment recording stopped, with nothing dragged, keyframed, or
            trimmed.
          </Lede>
        </div>

        <div className="mt-12 grid grid-cols-1 gap-6 lg:grid-cols-2">
          <figure className="scroll-reveal">
            <MediaPlaceholder id="before-raw" />
            <figcaption className="mt-3 flex items-center gap-2 text-sm text-muted-foreground">
              <span className="h-1.5 w-1.5 rounded-full bg-white/30" />
              Raw capture. Full screen, tiny cursor, no context.
            </figcaption>
          </figure>
          <figure className="scroll-reveal">
            <MediaPlaceholder id="before-capturecat" />
            <figcaption className="mt-3 flex items-center gap-2 text-sm text-muted-foreground">
              <span className="h-1.5 w-1.5 rounded-full bg-cyan-300/80" />
              CaptureCat export. Zoomed on the click, smooth cursor, framed.
            </figcaption>
          </figure>
        </div>
      </Container>
    </section>
  );
}
