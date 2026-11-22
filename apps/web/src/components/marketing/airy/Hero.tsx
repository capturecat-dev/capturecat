import { Globe } from "lucide-react";
import { Link } from "@tanstack/react-router";

import { AppleGlyph } from "../primitives";
import { DeviceLineup } from "./Devices";
import { AppStoreSlot, FoldableEditorScreen, IosAppScreen, IpadAppScreen } from "./IosApp";
import { MacDesktop } from "./MacDesktop";
import { InkLink, SoftAnchor } from "./primitives";

const PROOF = ["Free for personal use", "Open source", "Native Swift", "Runs in your browser too"];

/**
 * Dusk over the product's own canvas gradient, one line of promise, two
 * actions, then the product shot: the Mac editor on a laptop with the
 * iPhone app standing in front of it.
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
      <div className="air-floor" aria-hidden />

      <div className="mx-auto max-w-6xl px-6 pt-[132px] md:pt-[164px]">
        <div className="flex flex-col items-center text-center">
          <a
            href="#layouts"
            className="group inline-flex items-center gap-2 rounded-full bg-white/12 px-3.5 py-1.5 text-[13px] text-white/90 ring-1 ring-white/25 backdrop-blur-xl transition-colors hover:bg-white/18"
          >
            <span className="rounded-full bg-white px-1.5 py-px text-[11px] font-semibold text-[#3d2f8f]">New</span>
            CaptureCat for iPhone and iPad
            <span aria-hidden className="transition-transform group-hover:translate-x-0.5">›</span>
          </a>

          <h1 className="mt-7 max-w-4xl text-balance text-[44px] font-semibold leading-[1.02] tracking-[-0.04em] text-white drop-shadow-[0_2px_24px_rgb(40_20_120/0.35)] sm:text-6xl md:text-[80px]">
            Record your screen.
            <br />
            <span className="text-white/72">Skip the editing.</span>
          </h1>

          <p className="mt-6 max-w-xl text-pretty text-[17px] leading-relaxed text-white/82 md:text-[19px]">
            CaptureCat watches where you click and type, then adds the zooms, smooths the cursor and writes the
            captions. On your Mac, in your browser — and soon on iPhone and iPad.
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

          <ul className="mt-6 flex flex-wrap items-center justify-center gap-x-4 gap-y-1 text-[13px] text-white/72 sm:gap-x-3">
            {PROOF.map((item, i) => (
              <li key={item} className="flex items-center gap-3">
                {/* Dots only where the list sits on one line; wrapped lines never start with one. */}
                {i > 0 && <span aria-hidden className="hidden h-1 w-1 rounded-full bg-white/40 sm:inline-block" />}
                {item}
              </li>
            ))}
          </ul>
        </div>

        <div id="iphone" className="relative mx-auto mt-14 max-w-6xl scroll-mt-28 md:mt-20">
          <div className="-mx-3 sm:mx-0">
            <DeviceLineup
              label="CaptureCat on a Mac laptop, an iPad, an unfolded foldable phone and an iPhone. The Mac shows the editor zoomed in on a demo recording; the iPad shows the library; the foldable shows the editor split at the fold; the iPhone shows a synced project."
              laptopScreen={<MacDesktop priority />}
              tabletScreen={<IpadAppScreen />}
              foldableScreen={<FoldableEditorScreen />}
              phoneScreen={<IosAppScreen priority />}
            />
          </div>
          <div className="mx-auto mt-10 flex max-w-xl flex-col items-center text-center md:mt-12">
            <p className="text-pretty text-[15px] leading-relaxed text-[var(--cc-air-muted)] md:text-base">
              <strong className="font-semibold text-[var(--cc-air-ink)]">CaptureCat for iPhone and iPad.</strong> Record
              on your phone, edit anywhere. Every project syncs with your Mac and the web.
            </p>
            <AppStoreSlot />
            <Link
              to="/features"
              className="mt-3 text-[13px] text-[var(--cc-air-faint)] underline-offset-4 hover:text-[var(--cc-air-ink-2)] hover:underline"
            >
              See every feature
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}
