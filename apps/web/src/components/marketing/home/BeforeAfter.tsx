import { Container, Eyebrow, Lede, SectionTitle } from "../primitives";
import { Canvas, DemoFrame, KeysPill } from "./demo/parts";
import { useOffscreenPause, usePinnedSteps } from "./demo/hooks";

/**
 * One recording, pinned, with the treatment applied a layer per step: raw
 * capture → framed → smoothed cursor → zoom → keystrokes and captions.
 * Steps switch on scroll everywhere; browsers with CSS scroll timelines scrub
 * the stage continuously between them (styles/demos.css, `.ccd-ba-scroll`).
 */
const STEPS = [
  {
    title: "Raw capture.",
    body: "Full screen, tiny cursor, no context. This is what QuickTime gives you.",
  },
  {
    title: "Framed.",
    body: "The recording sits on a wallpaper with padding, rounded corners, and a soft shadow.",
  },
  {
    title: "A cursor that knew where it was going.",
    body: "The shaky pointer path is replaced with a damped spring, drawn bigger, with a ripple on every click.",
  },
  {
    title: "Zoomed on the click.",
    body: "The camera pushes in where you clicked and eases back out when you move on. Nobody placed that zoom.",
  },
  {
    title: "Keystrokes and captions, if you want them.",
    body: "Shortcuts show up as a pill in the frame, and your narration becomes captions, transcribed on your Mac.",
  },
];

export default function BeforeAfter() {
  const rootRef = usePinnedSteps<HTMLElement>();
  const stageRef = useOffscreenPause<HTMLDivElement>();
  return (
    <section ref={rootRef} className="ccd-pin ccd-ba relative isolate py-24" data-step="0">
      <Container>
        <div className="scroll-reveal flex flex-col items-start gap-4">
          <Eyebrow>Same recording, no manual edits</Eyebrow>
          <SectionTitle muted="Scroll, and watch it happen to one recording.">
            Here is what the auto edit actually does.
          </SectionTitle>
          <Lede>
            This is one twelve second recording. It starts as what QuickTime
            gives you. Each step below is something CaptureCat does to it on
            its own, with nothing dragged, keyframed, or trimmed.
          </Lede>
        </div>

        <div className="ccd-pin-grid ccd-ba-scroll mt-6 lg:mt-0">
          <div className="ccd-pin-stagecol">
            <div ref={stageRef} className="ccd">
              <DemoFrame blur={false}>
                <Canvas script="ba" typing>
                  <div className="ccd-caption">
                    <span>Name the project, then save it.</span>
                  </div>
                  <KeysPill keys={["⌘", "S"]} />
                </Canvas>
              </DemoFrame>
              <p className="mt-3 hidden items-center gap-2 text-sm text-muted-foreground lg:flex">
                <span className="h-1.5 w-1.5 rounded-full bg-cyan-300/80" />
                One recording. Every step is a switch you can turn off.
              </p>
            </div>
          </div>

          <ol className="relative">
            <span aria-hidden className="ccd-rail" />
            {STEPS.map((step, i) => (
              <li key={step.title} data-pin-step className="ccd-pin-step ccd-pin-step--ba" {...(i === 0 ? { "data-active": "" } : {})}>
                <p className="text-[13px] font-medium uppercase tracking-[0.08em] text-muted-foreground">
                  {i === 0 ? "Before" : `Step ${i}`}
                </p>
                <h3 className="mt-2 text-balance text-2xl font-medium tracking-[-0.02em] text-foreground md:text-3xl">
                  {step.title}
                </h3>
                <p className="mt-3 max-w-md text-[15.5px] leading-relaxed text-muted-foreground">{step.body}</p>
              </li>
            ))}
          </ol>
        </div>
      </Container>
    </section>
  );
}
