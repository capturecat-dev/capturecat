import { AppWindow, ChevronDown, CircleDot, Globe, Monitor, SlidersHorizontal } from "lucide-react";

import { PLATFORM_ROWS, PLATFORMS_SUMMARY } from "@/lib/platforms";
import { Ambient, AppleGlyph, Container, Eyebrow, Lede, PrimaryLink, SecondaryAnchor, SectionTitle } from "../primitives";
import { Canvas, DemoFrame, EditorMock } from "./demo/parts";
import { Meter } from "./demo/RecordingScene";
import { useOffscreenPause } from "./demo/hooks";

/**
 * The headline split: a native Mac app, and a browser app for every other
 * computer. The comparison is honest by construction: every row comes from
 * lib/platforms.ts, which cites the code behind each claim.
 */
export default function Platforms() {
  const pairRef = useOffscreenPause<HTMLDivElement>();
  return (
    <section id="anywhere" className="relative isolate scroll-mt-24 py-24">
      <Ambient variant="top" />
      <Container>
        <div className="scroll-reveal flex flex-col items-start gap-4">
          <Eyebrow>Mac app + browser app</Eyebrow>
          <SectionTitle muted="Windows, Linux, ChromeOS, anywhere with a current browser.">
            CaptureCat for Mac. CaptureCat in your browser.
          </SectionTitle>
          <Lede>
            The Mac app is native Swift and records everything it can see:
            clicks, keystrokes, and the path of the cursor. The browser app
            runs the same editor on WebGPU, so you can record, restyle, and
            export from any computer. Projects move between the two. Send one
            from the Mac with Open in Web Editor, and pull the edits back when
            you are done.
          </Lede>
        </div>

        <div ref={pairRef} className="ccd scroll-reveal mx-auto mt-12 max-w-4xl" aria-hidden>
          <div className="ccd-pair ccd-live">
            <div className="ccd-pair-win ccd-pair-mac">
              <EditorMock
                script="pair"
                title="Launch video — CaptureCat"
                duration={10}
                lanes={[
                  { name: "VIDEO" },
                  {
                    name: "EFFECTS",
                    blocks: [
                      { className: "ccd-b1", left: 11, width: 35, label: "Zoom 1.9×" },
                      { className: "ccd-b2", left: 52, width: 32, label: "Zoom 1.9×" },
                    ],
                  },
                ]}
              />
            </div>
            <div className="ccd-pair-win ccd-pair-web">
              <div className="ccd-tabs">
                <span className="ccd-lights">
                  <i />
                  <i />
                  <i />
                </span>
                <span className="ccd-tab">
                  <i />
                  Record · CaptureCat
                </span>
              </div>
              <div className="ccd-urlbar">
                <span className="ccd-url">
                  <b>app.capturecat.so</b>/record
                </span>
              </div>
              <div className="ccd-webapp">
                <div className="ccd-webside">
                  <span>Library</span>
                  <span className="is-on">Record</span>
                  <span>Projects</span>
                  <span>Team</span>
                  <span>Settings</span>
                </div>
                <div className="ccd-webmain">
                  <div className="ccd-webpreview">
                    <Canvas script="raw" />
                  </div>
                  <div className="ccd-webbar">
                    <div className="ccd-rec-tabs">
                      <span className="ccd-rec-pill" />
                      <span className="ccd-rec-tab is-on">
                        <Monitor strokeWidth={1.6} />
                        Display
                      </span>
                      <span className="ccd-rec-tab">
                        <AppWindow strokeWidth={1.6} />
                        Window
                      </span>
                      <span className="ccd-rec-tab">
                        <Globe strokeWidth={1.6} />
                        Tab
                      </span>
                    </div>
                    <span className="ccd-rec-div" />
                    <span className="ccd-rec-key">
                      <Monitor className="ccd-dim" />
                      Entire Screen
                      <ChevronDown className="ccd-dim" />
                    </span>
                    <span className="ccd-rec-div" />
                    <span className="ccd-rec-key">
                      <SlidersHorizontal className="ccd-dim" />
                      <Meter />
                      Mic · Cam
                    </span>
                    <span className="ccd-rec-record">
                      <CircleDot strokeWidth={2.2} />
                    </span>
                  </div>
                </div>
              </div>
            </div>
            <div className="ccd-sync">
              Open in Web Editor <i>⇄</i> Pull Web Edits
            </div>
          </div>
        </div>

        {/* One stacked surface, hairline rows (no card grid). */}
        <div className="scroll-reveal relative mt-14 overflow-hidden rounded-3xl border border-white/10 bg-white/[0.035] backdrop-blur-2xl">
          <span
            aria-hidden
            className="absolute inset-x-10 top-0 h-px bg-gradient-to-r from-transparent via-white/35 to-transparent"
          />
          <table className="w-full border-collapse text-left">
            <caption className="sr-only">CaptureCat for Mac compared with CaptureCat in the browser</caption>
            <thead className="hidden md:table-header-group">
              <tr className="border-b border-white/8">
                <th scope="col" className="w-[26%] px-7 py-5 text-[12px] font-medium uppercase tracking-[0.08em] text-muted-foreground">
                  <span className="sr-only">Capability</span>
                </th>
                <th scope="col" className="w-[37%] px-7 py-5">
                  <span className="inline-flex items-center gap-2 text-[15px] font-medium text-foreground">
                    <AppleGlyph className="h-4 w-4" />
                    Mac app
                  </span>
                </th>
                <th scope="col" className="w-[37%] px-7 py-5">
                  <span className="inline-flex items-center gap-2 text-[15px] font-medium text-foreground">
                    <Globe className="h-4 w-4 text-cyan-200" strokeWidth={1.75} />
                    Browser app
                  </span>
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-white/8">
              {PLATFORM_ROWS.map((row) => (
                <tr key={row.label} className="block px-6 py-5 md:table-row md:p-0">
                  <th scope="row" className="block pb-3 align-top font-normal md:table-cell md:px-7 md:py-5">
                    <span className="block text-[14.5px] font-medium text-foreground">{row.label}</span>
                    {row.note && <span className="mt-0.5 block text-[12.5px] text-muted-foreground">{row.note}</span>}
                  </th>
                  <td className="block py-1 align-top text-[14.5px] leading-relaxed text-muted-foreground md:table-cell md:px-7 md:py-5">
                    <span className="mr-2 inline-flex items-center gap-1.5 text-[11px] font-medium uppercase tracking-[0.08em] text-foreground/70 md:hidden">
                      <AppleGlyph className="h-3 w-3" /> Mac
                    </span>
                    {row.mac}
                  </td>
                  <td className="block py-1 align-top text-[14.5px] leading-relaxed text-muted-foreground md:table-cell md:px-7 md:py-5">
                    <span className="mr-2 inline-flex items-center gap-1.5 text-[11px] font-medium uppercase tracking-[0.08em] text-cyan-200/80 md:hidden">
                      <Globe className="h-3 w-3" strokeWidth={2} /> Browser
                    </span>
                    {row.web}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className="flex flex-col gap-5 border-t border-white/8 px-6 py-6 md:flex-row md:items-center md:justify-between md:px-7">
            <p className="max-w-xl text-[15px] leading-relaxed text-foreground/90">{PLATFORMS_SUMMARY}</p>
            <div className="flex shrink-0 flex-col gap-3 sm:flex-row">
              <PrimaryLink to="/download">
                <AppleGlyph />
                Download for Mac
              </PrimaryLink>
              <SecondaryAnchor href="/app/record">
                <Globe className="h-[18px] w-[18px]" strokeWidth={1.75} />
                Open the browser app
              </SecondaryAnchor>
            </div>
          </div>
        </div>
        <p className="mt-4 text-sm text-muted-foreground">
          The browser app needs a CaptureCat account, and keeps projects in your
          cloud storage on Pro.
        </p>
      </Container>
    </section>
  );
}
