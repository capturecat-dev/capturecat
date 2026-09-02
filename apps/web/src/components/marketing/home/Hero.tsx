import { Link } from "@tanstack/react-router";

import CaptureCatMark from "@/components/brand/CaptureCatMark";
import { MediaPlaceholder } from "../MediaPlaceholder";
import { TiltCard } from "../TiltCard";
import { Ambient, AppleGlyph, PrimaryLink, SecondaryLink } from "../primitives";

const PROOF = [
  "Free to record and export",
  "Open source, AGPL-3.0",
  "Native Swift, no Electron",
  "macOS 14 or later",
];

export default function Hero() {
  return (
    <section className="relative isolate overflow-hidden">
      <Ambient variant="hero" />

      <div className="mx-auto max-w-6xl px-6 pb-20 pt-10 md:pt-14">
        <div className="flex flex-col items-center text-center">
          <CaptureCatMark
            animated
            className="cc-float h-16 w-16 drop-shadow-[0_12px_40px_rgba(0,0,0,0.55)] md:h-20 md:w-20"
          />

          <Link
            to="/agents"
            className="group mt-6 inline-flex items-center gap-2 rounded-full border border-white/12 bg-white/[0.06] px-4 py-1.5 text-[13px] text-muted-foreground backdrop-blur-xl transition-colors hover:border-white/20 hover:text-foreground"
          >
            <span className="h-1.5 w-1.5 rounded-full bg-cyan-300/80" />
            New: Claude, Cursor, and Codex can edit your recordings
            <span aria-hidden className="transition-transform group-hover:translate-x-0.5">
              ›
            </span>
          </Link>

          <h1 className="mt-6 max-w-4xl text-balance text-5xl font-semibold leading-[1.04] tracking-[-0.03em] text-foreground md:text-7xl">
            Record your screen.{" "}
            <span className="bg-gradient-to-b from-white to-white/55 bg-clip-text text-transparent">
              Skip the editing.
            </span>
          </h1>

          <p className="mt-5 max-w-xl text-pretty text-lg leading-relaxed text-muted-foreground md:text-xl">
            CaptureCat is a Mac screen recorder that watches where you click
            and type, then adds the zooms, smooths the cursor, and writes the
            captions for you. What you see in the preview is what you get in
            the file.
          </p>

          <div className="mt-8 flex flex-col items-center gap-3 sm:flex-row">
            <PrimaryLink to="/download">
              <AppleGlyph />
              Download for Mac
            </PrimaryLink>
            <SecondaryLink to="/features">See every feature</SecondaryLink>
          </div>

          <ul className="mt-6 flex flex-wrap items-center justify-center gap-x-3 gap-y-1 text-[13px] text-muted-foreground">
            {PROOF.map((item, i) => (
              <li key={item} className="flex items-center gap-3">
                {i > 0 && <span aria-hidden className="h-1 w-1 rounded-full bg-white/25" />}
                {item}
              </li>
            ))}
          </ul>
        </div>

        <div className="relative mt-12 md:mt-16">
          <div
            aria-hidden
            className="absolute -inset-x-8 -top-8 bottom-10 -z-10 rounded-[3rem] bg-gradient-to-b from-white/[0.07] to-transparent blur-2xl"
          />
          <TiltCard>
            <MediaPlaceholder id="hero-loop" />
          </TiltCard>
        </div>
      </div>
    </section>
  );
}
