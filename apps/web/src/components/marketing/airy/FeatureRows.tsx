import type { ReactNode } from "react";
import { Captions, Link2, MousePointer2, UserRound, ZoomIn } from "lucide-react";

import { CameraBubble, Canvas, DemoFrame } from "../home/demo/parts";
import { useOffscreenPause } from "../home/demo/hooks";
import { SharePageDemo } from "../home/demo/ShareDemos";
import { CameraLayoutsDemo } from "./CameraLayoutsDemo";
import { AirChecks, AirContainer, AirLede, AirPill, AirTitle, SoftFrame } from "./primitives";

const CAPTION_WORDS = ["Click", "Create", "and", "the", "project", "is", "ready."];

/**
 * One feature scene from the editor recreations (styles/demos.css keys each
 * script off `.ccd-feat[data-step=N] .ccd-scene-N`), mounted on its own.
 */
function FeatureScene({ step, children }: { step: number; children: ReactNode }) {
  const ref = useOffscreenPause<HTMLDivElement>();
  return (
    <div ref={ref} className="ccd-pin ccd-feat" data-step={step}>
      <div className="ccd">
        <DemoFrame blur={false}>
          <div className="ccd-stage ccd-stage--wide" aria-hidden>
            <div className={`ccd-scene ccd-scene-${step}`} data-active="">
              {children}
            </div>
          </div>
        </DemoFrame>
      </div>
    </div>
  );
}

interface Row {
  id: string;
  pill: string;
  icon: ReactNode;
  title: ReactNode;
  body: string;
  checks: string[];
  visual: ReactNode;
  caption?: string;
}

const ROWS: Row[] = [
  {
    id: "zoom",
    pill: "Auto zoom",
    icon: <ZoomIn className="h-3.5 w-3.5" strokeWidth={2} />,
    title: "It zooms where you were working.",
    body: "Every click and keystroke is logged while you record. Afterwards CaptureCat groups them and places a zoom over each moment, easing in before the action and out after it.",
    checks: [
      "Zoom blocks you can move, stretch or delete",
      "Five animation styles, from Instant to Cinematic",
      "Follows the cursor through long drags and scrolls",
    ],
    visual: (
      <FeatureScene step={0}>
        <Canvas script="az" />
      </FeatureScene>
    ),
  },
  {
    id: "cursor",
    pill: "Cursor",
    icon: <MousePointer2 className="h-3.5 w-3.5" strokeWidth={2} />,
    title: "A cursor that knew where it was going.",
    body: "The shaky pointer path becomes a spring with weight. The hotspot never leaves the pixel it was recorded over, so every click still lands on its button.",
    checks: [
      "Tension, friction and mass you can tune",
      "Click ripples and optional key sounds",
      "Hides when idle, rests on the last frame",
    ],
    visual: (
      <FeatureScene step={1}>
        <Canvas script="cursor" />
      </FeatureScene>
    ),
  },
  {
    id: "layouts",
    pill: "Camera layouts",
    icon: <UserRound className="h-3.5 w-3.5" strokeWidth={2} />,
    title: "Your face, framed like a studio.",
    body: "The webcam is its own track. Keep it in a bubble, cut the background away, stand on a card with your head breaking out of the top, or split the frame top to bottom. Switch per span on the timeline and every change glides.",
    checks: [
      "Bubble, cutout, pop-out card and Split Screen",
      "Your real background, blurred, or a colour, gradient or image",
      "Borders, edge softness, camera left or right",
    ],
    visual: <CameraLayoutsDemo />,
  },
  {
    id: "captions",
    pill: "Captions",
    icon: <Captions className="h-3.5 w-3.5" strokeWidth={2} />,
    title: "Captions that write themselves, on your Mac.",
    body: "Your voice is transcribed on device. Nothing is uploaded to get a transcript. Edit any word, highlight words as you speak, and drag the captions wherever they read best.",
    checks: ["Six styles, or your own font and colours", "Word-by-word highlighting", "Fix a word without transcribing again"],
    visual: (
      <FeatureScene step={2}>
        <Canvas script="captions">
          <CameraBubble shape="circle" />
          <div className="ccd-caption">
            {CAPTION_WORDS.map((w, i) => (
              <b key={i} style={{ animationDelay: `${0.35 * i}s` }}>
                {w}{" "}
              </b>
            ))}
          </div>
        </Canvas>
      </FeatureScene>
    ),
  },
  {
    id: "share",
    pill: "Share",
    icon: <Link2 className="h-3.5 w-3.5" strokeWidth={2} />,
    title: "Send a link, not a file.",
    body: "Upload from the app and the link is on your clipboard when the bar fills. Viewers comment on the exact second, and you see where they stopped watching.",
    checks: ["Public or private, flip it any time", "Comments pinned to the timeline", "Views, watch time and the retention curve"],
    visual: <SharePageDemo />,
    caption: "Share pages and analytics come with Pro.",
  },
];

export default function FeatureRows() {
  return (
    <section className="relative py-24 md:py-32">
      <AirContainer>
        <div className="mx-auto max-w-3xl text-center">
          <AirTitle className="scroll-reveal">
            Everything after you press record.{" "}
            <span className="text-[var(--cc-air-faint)]">Done for you, undone in one click.</span>
          </AirTitle>
        </div>

        <div className="mt-20 space-y-28 md:mt-28 md:space-y-40">
          {ROWS.map((row, i) => (
            <div
              key={row.id}
              id={row.id}
              className={`grid scroll-mt-28 items-center gap-10 md:grid-cols-12 md:gap-14 ${
                i % 2 === 1 ? "md:[&>*:first-child]:order-2" : ""
              }`}
            >
              <div className="scroll-reveal md:col-span-5">
                <AirPill icon={row.icon}>{row.pill}</AirPill>
                <AirTitle as="h3" className="mt-5 !text-[30px] md:!text-[38px]">
                  {row.title}
                </AirTitle>
                <AirLede className="mt-4">{row.body}</AirLede>
                <AirChecks items={row.checks} />
              </div>
              <div className="scroll-reveal md:col-span-7">
                <SoftFrame>{row.visual}</SoftFrame>
                {row.caption ? (
                  <p className="mt-4 text-center text-[13px] text-[var(--cc-air-faint)]">{row.caption}</p>
                ) : null}
              </div>
            </div>
          ))}
        </div>
      </AirContainer>
    </section>
  );
}
