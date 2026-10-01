import { CameraBubble, DemoFrame, EditorMock, KeysPill } from "./parts";
import { useOffscreenPause } from "./hooks";

/**
 * The editor at work, as one 12 s loop: auto zoom drops its blocks on the
 * timeline, the playhead plays, the preview follows (cursor glide with motion
 * blur, click ripple, push in on easeOutExpo, typing, ⌘↩ pill, ease out).
 * Used by the home hero and the comparison pages.
 */
export function ProductLoop() {
  const ref = useOffscreenPause<HTMLDivElement>();
  return (
    <>
      <div ref={ref} className="ccd">
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
      <p className="sr-only">
        A recreation of the CaptureCat editor: the cursor clicks a form field, the preview zooms in on it, the
        name is typed, and the timeline shows the zoom blocks auto zoom placed.
      </p>
    </>
  );
}
