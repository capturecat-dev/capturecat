import {
  Crosshair,
  MousePointer2,
  Captions,
  Frame,
  Video,
  EyeOff,
  SlidersHorizontal,
} from "lucide-react";

import { Container, IconTile, SectionTitle } from "../primitives";
import { CameraBubble, Canvas, DemoFrame, FakeApp, Timeline } from "./demo/parts";
import { useOffscreenPause, usePinnedSteps } from "./demo/hooks";

interface Showcase {
  icon: typeof Crosshair;
  eyebrow: string;
  title: string;
  body: string;
  details: string[];
}

const SHOWCASES: Showcase[] = [
  {
    icon: Crosshair,
    eyebrow: "Auto zoom",
    title: "It zooms where you were working, not where a rule says to.",
    body:
      "Every click and keystroke is logged during the recording. Afterwards CaptureCat groups them into clusters and places a zoom block over each one. A burst of typing keeps the camera held. Three quick clicks in one corner get a deeper push in than a single click in the middle.",
    details: [
      "Zoom from 0.3x to 6x with a draggable focal point",
      "Five animation styles per block, from Instant to Cinematic",
      "Follow cursor mode for long drags and scrolls",
      "Your manual zooms are respected. Auto zoom routes around them",
    ],
  },
  {
    icon: MousePointer2,
    eyebrow: "Cursor",
    title: "A cursor that looks like it knew where it was going.",
    body:
      "The raw pointer path is replaced with a damped spring. You choose the tension, friction, and mass. The hotspot never leaves the pixel it was recorded over, so a click still lands on the button it clicked. Ripples and synthesized click sounds are optional.",
    details: [
      "Five cursor styles and size scaling",
      "Tilt, stretch, and inertia so movement has weight",
      "Click ripples, plus Thock, Clacky, and Typewriter key sounds",
      "Auto hide when idle, freeze at the end for a clean last frame",
    ],
  },
  {
    icon: Captions,
    eyebrow: "Captions",
    title: "Captions transcribed on your Mac, styled like titles.",
    body:
      "Audio is transcribed on device. Nothing is uploaded to get a transcript. Segments are editable, words can highlight in time with your voice, and the block sits wherever you drag it on the preview.",
    details: [
      "Six style presets, or your own font, colour, and background",
      "Karaoke word highlighting",
      "Edit any word without re-running the transcript",
      "Optional keystroke overlay pill for shortcut heavy tutorials",
    ],
  },
  {
    icon: Frame,
    eyebrow: "Framing",
    title: "One recording, framed for the docs, the tweet, and the App Store.",
    body:
      "Put the window on a gradient, a real macOS wallpaper, a solid colour, your own image, or nothing at all. Add padding and a soft shadow. Swap the aspect ratio from 16:9 to 9:16 without re-recording, and the zoom focal points come along.",
    details: [
      "Rounded, squircle, or square frames",
      "Photoreal iPhone and iPad bezels for device recordings",
      "A clean replacement menu bar with your app name and a 9:41 clock",
      "Motion blur and background parallax for depth",
    ],
  },
  {
    icon: Video,
    eyebrow: "Camera",
    title: "A camera bubble that is its own track.",
    body:
      "Your webcam is recorded separately, so you can move it, reshape it, or hide it for a stretch after the fact. Put a name tag under it. Switch the layout per span: bubble, camera only, side by side, or screen only.",
    details: [
      "Circle, squircle, rounded, or square, in any corner or anywhere else",
      "Colour grades, film looks, ring light, borders, mirror, and 3D tilt",
      "Per span layouts on the timeline",
      "Mic with Voice Isolation, system audio, and voice over on separate faders",
    ],
  },
  {
    icon: EyeOff,
    eyebrow: "Focus and privacy",
    title: "Hide the API key. Point at the button.",
    body:
      "Drag a blur or pixelate region over anything you should not have on screen. Feathered edges, and it can animate over time to follow a moving element. Spotlights do the opposite: they dim everything except the region you want people looking at.",
    details: [
      "Blur and pixelate with feathered edges",
      "Spotlights that dim the rest of the screen",
      "Depth focus: one region sharp, the rest tilt shifted",
      "All of it drawn directly on the preview",
    ],
  },
  {
    icon: SlidersHorizontal,
    eyebrow: "Timeline",
    title: "When you do want to edit, it is a real editor.",
    body:
      "Five lanes: video, effects, focus, annotations, and voice. Trim, split with Command B, cut sections out, and add speed regions to skip the slow parts. Every automatic effect lives here as an ordinary block, so undo works the way you expect.",
    details: [
      "Snapping, full undo and redo, and keyboard shortcuts throughout",
      "Record narration straight onto the voice lane",
      "Text, arrows, callouts, shapes, freehand, and tap indicators",
      "Intro slide and curtain openers with your logo",
    ],
  },
];

const CAPTION_WORDS = ["Click", "New", "project,", "give", "it", "a", "name,", "then", "save."];

/**
 * Pinned: one stage, a mode per feature. The copy scrolls; the stage swaps
 * to that feature's recreation (zooming across fields, smoothed vs raw
 * cursor, karaoke captions, backgrounds and 9:16, the camera bubble, blur
 * and spotlight, the five-lane timeline).
 */
export default function FeatureShowcase() {
  const rootRef = usePinnedSteps<HTMLElement>();
  const stageRef = useOffscreenPause<HTMLDivElement>();
  return (
    <section id="features" ref={rootRef} className="ccd-pin ccd-feat relative isolate py-24" data-step="0">
      <div aria-hidden className="pointer-events-none absolute inset-0 -z-10 overflow-hidden">
        <div
          className="scroll-parallax-fast absolute left-[10%] top-[20%] h-96 w-96 rounded-full blur-3xl"
          style={{ background: "rgba(80,220,255,0.06)" }}
        />
        <div
          className="scroll-parallax-fast absolute right-[8%] top-[60%] h-80 w-80 rounded-full blur-3xl"
          style={{ background: "rgba(255,95,158,0.05)" }}
        />
      </div>

      <Container>
        <SectionTitle className="scroll-reveal" muted="Each one is on by default and off in one click.">
          The parts that used to be an afternoon in a video editor.
        </SectionTitle>

        <div className="ccd-pin-grid ccd-pin-grid--flip mt-6 lg:mt-0">
          <div className="ccd-pin-stagecol">
            <div ref={stageRef} className="ccd">
              <DemoFrame blur={false}>
                <div className="ccd-stage ccd-stage--wide" aria-hidden>
                  <div className="ccd-scene ccd-scene-0">
                    <Canvas script="az" />
                  </div>
                  <div className="ccd-scene ccd-scene-1">
                    <Canvas script="cursor" />
                  </div>
                  <div className="ccd-scene ccd-scene-2">
                    <Canvas script="captions">
                      <CameraBubble shape="circle" />
                      <div className="ccd-caption">
                        {CAPTION_WORDS.map((w, i) => (
                          <span key={w}>
                            {w}
                            <b style={{ animationDelay: `${0.3 + i * 0.45}s` }}>{w}</b>
                          </span>
                        ))}
                      </div>
                    </Canvas>
                  </div>
                  <div className="ccd-scene ccd-scene-3">
                    <Canvas script="framing">
                      <div className="ccd-vert-dim" />
                      <div className="ccd-vert">
                        <div className="ccd-wall" />
                        <div className="ccd-vert-card">
                          <FakeApp />
                        </div>
                      </div>
                    </Canvas>
                  </div>
                  <div className="ccd-scene ccd-scene-4">
                    <Canvas script="camera">
                      <CameraBubble tag shape="both" />
                    </Canvas>
                  </div>
                  <div className="ccd-scene ccd-scene-5">
                    <Canvas script="focus">
                      <div className="ccd-blurbox" />
                      <div className="ccd-spot" />
                    </Canvas>
                  </div>
                  <div className="ccd-scene ccd-scene-6">
                    <div className="ccd-tl-host">
                      <div className="ccd-tl-toolbar">
                        <span className="ccd-key ccd-kb">Split ⌘B</span>
                        <span className="ccd-key">Cut</span>
                        <span className="ccd-key">Speed 2×</span>
                      </div>
                      <Timeline
                        duration={12}
                        clicks={[0.2, 0.52, 0.81]}
                        videoExtras={
                          <>
                            <span className="ccd-split" />
                            <span className="ccd-speed">2×</span>
                          </>
                        }
                        lanes={[
                          { name: "VIDEO" },
                          { name: "VOICE" },
                          {
                            name: "EFFECTS",
                            blocks: [
                              { className: "ccd-b1", left: 12, width: 20, label: "Zoom 2×" },
                              { className: "ccd-b2", left: 44, width: 18, label: "Zoom 2.6×" },
                            ],
                          },
                          {
                            name: "FOCUS",
                            blocks: [{ className: "ccd-b3", left: 64, width: 22, label: "Blur" }],
                          },
                          {
                            name: "ANNOTATE",
                            blocks: [
                              { className: "ccd-b4", left: 6, width: 16, label: "Title" },
                              { className: "ccd-b5", left: 70, width: 14, label: "Arrow" },
                            ],
                          },
                        ]}
                      />
                    </div>
                  </div>
                </div>
              </DemoFrame>
            </div>
          </div>

          <div>
            {SHOWCASES.map((item, i) => (
              <div key={item.eyebrow} data-pin-step className="ccd-pin-step" {...(i === 0 ? { "data-active": "" } : {})}>
                <IconTile>
                  <item.icon className="h-[18px] w-[18px]" strokeWidth={1.75} />
                </IconTile>
                <p className="mt-5 text-[13px] font-medium uppercase tracking-[0.08em] text-muted-foreground">
                  {item.eyebrow}
                </p>
                <h3 className="mt-2 text-balance text-2xl font-medium tracking-[-0.02em] text-foreground md:text-3xl">
                  {item.title}
                </h3>
                <p className="mt-4 text-[15.5px] leading-relaxed text-muted-foreground">{item.body}</p>
                <ul className="mt-5 space-y-2">
                  {item.details.map((d) => (
                    <li key={d} className="flex gap-2.5 text-[14px] leading-relaxed text-muted-foreground">
                      <span aria-hidden className="mt-[8px] h-1 w-1 shrink-0 rounded-full bg-cyan-300/60" />
                      {d}
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
        </div>
      </Container>
    </section>
  );
}
