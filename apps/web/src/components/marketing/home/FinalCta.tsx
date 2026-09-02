import CaptureCatMark from "@/components/brand/CaptureCatMark";
import { Ambient, AppleGlyph, Container, PrimaryLink, SecondaryLink } from "../primitives";

export default function FinalCta() {
  return (
    <section className="relative isolate py-28">
      <Ambient variant="bottom" />
      <Container>
        <div className="relative overflow-hidden rounded-[32px] border border-white/12 bg-white/[0.05] px-8 py-16 text-center backdrop-blur-2xl md:px-16">
          <span
            aria-hidden
            className="absolute inset-x-16 top-0 h-px bg-gradient-to-r from-transparent via-white/40 to-transparent"
          />
          <CaptureCatMark animated className="mx-auto h-14 w-14" />
          <h2 className="mx-auto mt-6 max-w-2xl text-balance text-4xl font-semibold tracking-[-0.03em] text-foreground md:text-5xl">
            Record one thing today and see what comes out.
          </h2>
          <p className="mx-auto mt-4 max-w-lg text-pretty text-lg leading-relaxed text-muted-foreground">
            The download is free, there is no account to make, and your first
            export is ready about a minute after you stop recording.
          </p>
          <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <PrimaryLink to="/download">
              <AppleGlyph />
              Download for Mac
            </PrimaryLink>
            <SecondaryLink to="/pricing">See pricing</SecondaryLink>
          </div>
        </div>
      </Container>
    </section>
  );
}
