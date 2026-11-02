import { Globe } from "lucide-react";
import { Link } from "@tanstack/react-router";

import { AppleGlyph } from "../primitives";
import { ProductLoop } from "../home/demo/ProductLoop";
import { InkLink, SoftAnchor, SoftFrame } from "./primitives";

const PROOF = ["Free for personal use", "Open source", "Native Swift", "Runs in your browser too"];

/**
 * Dusk over the product's own canvas gradient, one line of promise, two
 * actions, then the editor itself rising out of the sky.
 */
export default function AirHero() {
  return (
    // Pulled up under the sticky nav pill (68 px) so the sky starts at the very top.
    <section className="relative isolate -mt-[68px] overflow-hidden pb-10">
      <div className="air-sky" aria-hidden />
      <div className="air-stars" aria-hidden />
      <svg className="air-dunes" viewBox="0 0 1440 260" preserveAspectRatio="none" aria-hidden>
        <defs>
          <linearGradient id="airDuneA" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#ffffff" stopOpacity="0.32" />
            <stop offset="1" stopColor="#ffffff" stopOpacity="0" />
          </linearGradient>
          <linearGradient id="airDuneB" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#ffd6c8" stopOpacity="0.7" />
            <stop offset="1" stopColor="#fbfbfd" stopOpacity="1" />
          </linearGradient>
        </defs>
        <path d="M0 140 C 240 70 420 70 640 120 S 1060 190 1240 120 S 1400 80 1440 92 V260 H0z" fill="url(#airDuneA)" />
        <path d="M0 190 C 220 140 460 150 720 182 S 1180 210 1440 168 V260 H0z" fill="url(#airDuneB)" />
      </svg>

      <div className="mx-auto max-w-6xl px-6 pt-[132px] md:pt-[164px]">
        <div className="flex flex-col items-center text-center">
          <a
            href="#layouts"
            className="group inline-flex items-center gap-2 rounded-full bg-white/12 px-3.5 py-1.5 text-[13px] text-white/90 ring-1 ring-white/25 backdrop-blur-xl transition-colors hover:bg-white/18"
          >
            <span className="rounded-full bg-white px-1.5 py-px text-[11px] font-semibold text-[#3d2f8f]">New</span>
            Camera layouts: cutout, pop-out and split screen
            <span aria-hidden className="transition-transform group-hover:translate-x-0.5">›</span>
          </a>

          <h1 className="mt-7 max-w-4xl text-balance text-[44px] font-semibold leading-[1.02] tracking-[-0.04em] text-white drop-shadow-[0_2px_24px_rgb(40_20_120/0.35)] sm:text-6xl md:text-[80px]">
            Record your screen.
            <br />
            <span className="text-white/72">Skip the editing.</span>
          </h1>

          <p className="mt-6 max-w-xl text-pretty text-[17px] leading-relaxed text-white/82 md:text-[19px]">
            CaptureCat watches where you click and type, then adds the zooms, smooths the cursor and writes the
            captions. On your Mac, or in your browser.
          </p>

          <div className="mt-8 flex flex-col items-center gap-3 sm:flex-row">
            <InkLink to="/download" light>
              <AppleGlyph />
              Download for Mac
            </InkLink>
            <SoftAnchor href="#everywhere" glass>
              <Globe className="h-[18px] w-[18px]" strokeWidth={1.75} />
              Use it in the browser
            </SoftAnchor>
          </div>

          <ul className="mt-6 flex flex-wrap items-center justify-center gap-x-3 gap-y-1 text-[13px] text-white/72">
            {PROOF.map((item, i) => (
              <li key={item} className="flex items-center gap-3">
                {i > 0 && <span aria-hidden className="h-1 w-1 rounded-full bg-white/40" />}
                {item}
              </li>
            ))}
          </ul>
        </div>

        <div className="relative mx-auto mt-14 max-w-5xl md:mt-20">
          <SoftFrame halo={false}>
            <ProductLoop />
          </SoftFrame>
          <p className="mt-4 text-center text-[13px] text-[var(--cc-air-faint)]">
            The editor, recreated: auto zoom places its blocks, then the preview follows the click.{" "}
            <Link to="/features" className="text-[var(--cc-air-ink-2)] underline-offset-4 hover:underline">
              See every feature
            </Link>
          </p>
        </div>
      </div>
    </section>
  );
}
