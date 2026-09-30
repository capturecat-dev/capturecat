import { Globe } from "lucide-react";
import { Link } from "@tanstack/react-router";

import CaptureCatMark from "@/components/brand/CaptureCatMark";
import { TiltCard } from "../TiltCard";
import { Ambient, AppleGlyph, PrimaryLink, SecondaryAnchor } from "../primitives";
import { DemoFrame, EditorMock, KeysPill, CameraBubble } from "./demo/parts";
import { useOffscreenPause } from "./demo/hooks";

const PROOF = [
  "Free to record and export",
  "Open source, AGPL-3.0",
  "Native Swift, no Electron",
  "macOS 14 or later",
];

export default function Hero() {
  const demoRef = useOffscreenPause<HTMLDivElement>();
  return (
    <section className="relative isolate overflow-hidden">
      <Ambient variant="hero" />

      <div className="mx-auto max-w-6xl px-6 pb-20 pt-10 md:pt-14">
        <div className="flex flex-col items-center text-center">
          <CaptureCatMark
            animated
            className="cc-float h-16 w-16 drop-shadow-[0_12px_40px_rgba(0,0,0,0.55)] md:h-20 md:w-20"
          />

          <a
            href="#anywhere"
            className="group mt-6 inline-flex items-center gap-2 rounded-full border border-white/12 bg-white/[0.06] px-4 py-1.5 text-[13px] text-muted-foreground backdrop-blur-xl transition-colors hover:border-white/20 hover:text-foreground"
          >
            <span className="h-1.5 w-1.5 rounded-full bg-cyan-300/80" />
            New: CaptureCat runs in your browser too
            <span aria-hidden className="transition-transform group-hover:translate-x-0.5">
              ›
            </span>
          </a>

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

          {/* The headline split: native on the Mac, and a browser app everywhere else. */}
          <div className="mt-7 inline-flex max-w-full flex-col items-stretch overflow-hidden rounded-3xl border border-white/12 bg-white/[0.05] text-left shadow-[inset_0_1px_0_rgba(255,255,255,0.08)] backdrop-blur-xl sm:flex-row sm:rounded-full">
            <span className="flex items-center gap-3 px-5 py-3 sm:py-2.5">
              <AppleGlyph className="h-4 w-4 shrink-0 text-foreground" />
              <span className="text-[13.5px] leading-tight">
                <span className="font-medium text-foreground">CaptureCat for Mac</span>
                <span className="block text-muted-foreground sm:inline"><span className="hidden sm:inline"> · </span>native Swift</span>
              </span>
            </span>
            <span aria-hidden className="h-px w-full bg-white/10 sm:h-auto sm:w-px" />
            <span className="flex items-center gap-3 px-5 py-3 sm:py-2.5">
              <Globe className="h-4 w-4 shrink-0 text-cyan-200" strokeWidth={1.75} />
              <span className="text-[13.5px] leading-tight">
                <span className="font-medium text-foreground">CaptureCat in your browser</span>
                <span className="block text-muted-foreground sm:inline"><span className="hidden sm:inline"> · </span>Windows, Linux, ChromeOS</span>
              </span>
            </span>
          </div>

          <div className="mt-7 flex flex-col items-center gap-3 sm:flex-row">
            <PrimaryLink to="/download">
              <AppleGlyph />
              Download for Mac
            </PrimaryLink>
            <SecondaryAnchor href="#anywhere">
              <Globe className="h-[18px] w-[18px]" strokeWidth={1.75} />
              Use it in the browser
            </SecondaryAnchor>
          </div>

          <ul className="mt-6 flex flex-wrap items-center justify-center gap-x-3 gap-y-1 text-[13px] text-muted-foreground">
            {PROOF.map((item, i) => (
              <li key={item} className="flex items-center gap-3">
                {i > 0 && <span aria-hidden className="h-1 w-1 rounded-full bg-white/25" />}
                {item}
              </li>
            ))}
            <li className="flex items-center gap-3">
              <span aria-hidden className="h-1 w-1 rounded-full bg-white/25" />
              <Link to="/features" className="text-foreground/85 underline-offset-4 hover:text-foreground hover:underline">
                See every feature
              </Link>
            </li>
          </ul>
        </div>

        <div className="relative mx-auto mt-12 max-w-5xl md:mt-16">
          <div
            aria-hidden
            className="absolute -inset-x-8 -top-8 bottom-10 -z-10 rounded-[3rem] bg-gradient-to-b from-white/[0.07] to-transparent blur-2xl"
          />
          <TiltCard>
            <div ref={demoRef} className="ccd">
              <DemoFrame>
                <EditorMock
                  script="hero"
                  title="Launch video"
                  duration={10}
                  motionBlur
                  lanes={[
                    { name: "VIDEO" },
                    { name: "VOICE" },
                    {
                      name: "EFFECTS",
                      blocks: [
                        { className: "ccd-b1", left: 11, width: 35, label: "Zoom 1.9×" },
                        { className: "ccd-b2", left: 52, width: 32, label: "Zoom 1.9×" },
                      ],
                    },
                  ]}
                  overlays={
                    <>
                      <CameraBubble />
                      <KeysPill keys={["⌘", "↩"]} />
                    </>
                  }
                />
              </DemoFrame>
            </div>
          </TiltCard>
          <p className="sr-only">
            A recreation of the CaptureCat editor: the cursor clicks a form field, the
            preview zooms in on it, the name is typed, and the timeline shows the zoom
            blocks auto zoom placed.
          </p>
        </div>
      </div>
    </section>
  );
}
