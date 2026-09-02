import { MediaPlaceholder } from "../MediaPlaceholder";
import { Container, SectionTitle, Ambient } from "../primitives";
import type { ShotId } from "@/lib/media-shots";

const STEPS: Array<{ title: string; body: string; shot: ShotId }> = [
  {
    title: "Pick what to record",
    body:
      "A display, a window, a dragged area, an iPhone over USB, or a web page by URL. Turn on the camera bubble and mic if you want them. Press record, or use the global shortcut from any app.",
    shot: "step-record",
  },
  {
    title: "Stop, and the edit is waiting",
    body:
      "While you record, CaptureCat stores every click, keystroke, and scroll as data, not just pixels. When you stop, it reads that data and places zoom blocks where you were working. Tight click clusters get a deeper push in. Typing extends the hold.",
    shot: "step-auto-edit",
  },
  {
    title: "Change anything on the preview",
    body:
      "Wallpaper, padding, shadow, device frame, cursor style, captions. Everything is draggable straight on the preview, and every zoom the app placed is a normal block on the timeline you can move, resize, or delete.",
    shot: "step-style",
  },
  {
    title: "Export a file or send a link",
    body:
      "MP4 or MOV up to 4K at 60 fps, with the same maths in the encoder as in the preview. Or upload from inside the app and copy a share link that comes with comments and viewer analytics.",
    shot: "step-share",
  },
];

export default function HowItWorks() {
  return (
    <section id="how-it-works" className="relative isolate py-24">
      <Ambient variant="top" />
      <Container>
        <SectionTitle className="scroll-reveal" muted="Four steps, and only the first one is yours.">
          How a recording becomes a video
        </SectionTitle>

        <ol className="mt-14 space-y-20">
          {STEPS.map((step, i) => (
            <li
              key={step.title}
              className={`scroll-reveal grid grid-cols-1 items-center gap-8 lg:grid-cols-12 lg:gap-14`}
            >
              <div className={`lg:col-span-5 ${i % 2 === 1 ? "lg:order-2" : ""}`}>
                <div className="flex items-center gap-3">
                  <span className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-white/12 bg-white/[0.07] text-sm font-medium shadow-[inset_0_1px_0_rgba(255,255,255,0.18)]">
                    {i + 1}
                  </span>
                  <h3 className="text-2xl font-medium tracking-[-0.02em] text-foreground">
                    {step.title}
                  </h3>
                </div>
                <p className="mt-4 text-[15.5px] leading-relaxed text-muted-foreground">
                  {step.body}
                </p>
              </div>
              <div className={`lg:col-span-7 ${i % 2 === 1 ? "lg:order-1" : ""}`}>
                <MediaPlaceholder id={step.shot} />
              </div>
            </li>
          ))}
        </ol>
      </Container>
    </section>
  );
}
