import { Container, SectionTitle, Ambient } from "../primitives";
import { Canvas, Cursor, DemoFrame, EditorMock } from "./demo/parts";
import { RecordingDesktop } from "./demo/RecordingScene";
import { ExportScene } from "./demo/Scenes";
import { useOffscreenPause, usePinnedSteps } from "./demo/hooks";

const STEPS: Array<{ title: string; body: string }> = [
  {
    title: "Pick what to record",
    body:
      "A display, a window, a dragged area, an iPhone over USB, or a web page by URL. Turn on the camera bubble and mic if you want them. Press record from the menu bar, from any app.",
  },
  {
    title: "Stop, and the edit is waiting",
    body:
      "While you record, CaptureCat stores every click, keystroke, and scroll as data, not just pixels. When you stop, it reads that data and places zoom blocks where you were working. Tight click clusters get a deeper push in. Typing extends the hold.",
  },
  {
    title: "Change anything on the preview",
    body:
      "Wallpaper, padding, shadow, device frame, cursor style, captions. Everything is draggable straight on the preview, and every zoom the app placed is a normal block on the timeline you can move, resize, or delete.",
  },
  {
    title: "Export a file or send a link",
    body:
      "MP4 or MOV up to 4K at 60 fps, with the same maths in the encoder as in the preview. Or upload from inside the app and copy a share link that comes with comments and viewer analytics.",
  },
];

/**
 * Pinned: the stage holds while the four steps scroll past it. Each step has
 * its own scene, rebuilt from the real UI — the recording panel and its
 * countdown dial, the editor filling its timeline, the inspector restyling
 * the preview, and the export sheet handing over a share link.
 */
export default function HowItWorks() {
  const rootRef = usePinnedSteps<HTMLElement>();
  const stageRef = useOffscreenPause<HTMLDivElement>();
  return (
    <section id="how-it-works" ref={rootRef} className="ccd-pin ccd-how relative isolate py-24" data-step="0">
      <Ambient variant="top" />
      <Container>
        <SectionTitle className="scroll-reveal" muted="Four steps, and only the first one is yours.">
          How a recording becomes a video
        </SectionTitle>

        <div className="ccd-pin-grid mt-6 lg:mt-0">
          <div className="ccd-pin-stagecol">
            <div ref={stageRef} className="ccd">
              <DemoFrame blur={false}>
                <div className="ccd-stage" aria-hidden>
                  <div className="ccd-scene ccd-scene-0" data-active="">
                    <RecordingDesktop />
                  </div>
                  <div className="ccd-scene ccd-scene-1">
                    <div className="ccd-desk" />
                    <div className="ccd-editor-host">
                      <EditorMock
                        script="how"
                        title="Launch video"
                        duration={10}
                        clicks={[0.19, 0.46, 0.8]}
                        lanes={[
                          { name: "VIDEO" },
                          {
                            name: "EFFECTS",
                            blocks: [
                              { className: "ccd-b1", left: 8, width: 22, label: "Zoom 1.9×" },
                              { className: "ccd-b2", left: 38, width: 24, label: "Zoom 2.4×" },
                              { className: "ccd-b3", left: 70, width: 22, label: "Zoom 1.9×" },
                            ],
                          },
                        ]}
                      />
                    </div>
                  </div>
                  <div className="ccd-scene ccd-scene-2">
                    <Canvas script="style" className="ccd-style-canvas" />
                    <div className="ccd-insp">
                      <div>
                        <h5>Background</h5>
                        <div className="ccd-swatches">
                          <i />
                          <i />
                          <i />
                          <i />
                          <span className="ccd-swatch-ring" />
                        </div>
                      </div>
                      <div>
                        <h5>Padding</h5>
                        <div className="ccd-slider">
                          <span className="ccd-slider-track" />
                          <span className="ccd-slider-thumb ccd-thumb-pad" />
                        </div>
                      </div>
                      <div>
                        <h5>Shadow</h5>
                        <div className="ccd-slider">
                          <span className="ccd-slider-track" />
                          <span className="ccd-slider-thumb ccd-thumb-shadow" />
                        </div>
                      </div>
                      <div>
                        <h5>Frame</h5>
                        <div className="ccd-seg">
                          <span>Rounded</span>
                          <span>Squircle</span>
                          <span>Square</span>
                        </div>
                      </div>
                    </div>
                    <span className="ccd-scene-track">
                      <Cursor />
                    </span>
                  </div>
                  <div className="ccd-scene ccd-scene-3 ccd-x-export">
                    <ExportScene />
                  </div>
                </div>
              </DemoFrame>
            </div>
          </div>

          <ol className="relative">
            {STEPS.map((step, i) => (
              <li key={step.title} data-pin-step className="ccd-pin-step" {...(i === 0 ? { "data-active": "" } : {})}>
                <div className="flex items-center gap-3">
                  <span className="ccd-stepnum inline-flex h-9 w-9 items-center justify-center rounded-full border border-white/12 bg-white/[0.07] text-sm font-medium shadow-[inset_0_1px_0_rgba(255,255,255,0.18)]">
                    {i + 1}
                  </span>
                  <h3 className="text-2xl font-medium tracking-[-0.02em] text-foreground">{step.title}</h3>
                </div>
                <p className="mt-4 max-w-lg text-[15.5px] leading-relaxed text-muted-foreground">{step.body}</p>
              </li>
            ))}
          </ol>
        </div>
      </Container>
    </section>
  );
}
