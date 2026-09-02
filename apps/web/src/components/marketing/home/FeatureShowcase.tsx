import {
  Crosshair,
  MousePointer2,
  Captions,
  Frame,
  Video,
  EyeOff,
  SlidersHorizontal,
} from "lucide-react";

import { MediaPlaceholder } from "../MediaPlaceholder";
import { Container, IconTile, SectionTitle } from "../primitives";
import type { ShotId } from "@/lib/media-shots";

interface Showcase {
  icon: typeof Crosshair;
  eyebrow: string;
  title: string;
  body: string;
  details: string[];
  shot: ShotId;
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
    shot: "feature-auto-zoom",
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
    shot: "feature-cursor",
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
    shot: "feature-captions",
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
    shot: "feature-framing",
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
    shot: "feature-camera",
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
    shot: "feature-focus",
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
    shot: "feature-timeline",
  },
];

export default function FeatureShowcase() {
  return (
    <section id="features" className="relative isolate py-24">
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

        <div className="mt-16 space-y-24">
          {SHOWCASES.map((item, i) => (
            <div
              key={item.eyebrow}
              className="scroll-reveal grid grid-cols-1 items-center gap-8 lg:grid-cols-12 lg:gap-14"
            >
              <div className={`lg:col-span-5 ${i % 2 === 1 ? "lg:order-2" : ""}`}>
                <IconTile>
                  <item.icon className="h-[18px] w-[18px]" strokeWidth={1.75} />
                </IconTile>
                <p className="mt-5 text-[13px] font-medium uppercase tracking-[0.08em] text-muted-foreground">
                  {item.eyebrow}
                </p>
                <h3 className="mt-2 text-balance text-2xl font-medium tracking-[-0.02em] text-foreground md:text-3xl">
                  {item.title}
                </h3>
                <p className="mt-4 text-[15.5px] leading-relaxed text-muted-foreground">
                  {item.body}
                </p>
                <ul className="mt-5 space-y-2">
                  {item.details.map((d) => (
                    <li
                      key={d}
                      className="flex gap-2.5 text-[14px] leading-relaxed text-muted-foreground"
                    >
                      <span
                        aria-hidden
                        className="mt-[8px] h-1 w-1 shrink-0 rounded-full bg-cyan-300/60"
                      />
                      {d}
                    </li>
                  ))}
                </ul>
              </div>
              <div className={`lg:col-span-7 ${i % 2 === 1 ? "lg:order-1" : ""}`}>
                <MediaPlaceholder id={item.shot} />
              </div>
            </div>
          ))}
        </div>
      </Container>
    </section>
  );
}
