import type { ReactNode } from "react";

import { DemoFrame } from "./parts";
import { useOffscreenPause, usePinnedSteps } from "./hooks";

/**
 * A pinned scroll story: the stage (one `.ccd-stage` of `.ccd-scene`s) holds
 * still while the steps scroll past; each step activates its scene. Same
 * mechanics as the home page's How it works and feature showcase.
 */
export function PinnedStory({
  className = "",
  stage,
  steps,
  flip = false,
  wide = false,
}: {
  /** Extra classes on the root (scopes the scene CSS). */
  className?: string;
  /** The scenes, in step order. */
  stage: ReactNode;
  steps: ReactNode[];
  /** Stage on the left on wide screens. */
  flip?: boolean;
  /** 16:9 stage instead of 16:10. */
  wide?: boolean;
}) {
  const rootRef = usePinnedSteps<HTMLDivElement>();
  const stageRef = useOffscreenPause<HTMLDivElement>();
  return (
    <div ref={rootRef} className={`ccd-pin ${className}`} data-step="0">
      <div className={`ccd-pin-grid ${flip ? "ccd-pin-grid--flip" : ""}`}>
        <div className="ccd-pin-stagecol">
          <div ref={stageRef} className="ccd">
            <DemoFrame blur={false}>
              <div className={`ccd-stage ${wide ? "ccd-stage--wide" : ""}`} aria-hidden>
                {stage}
              </div>
            </DemoFrame>
          </div>
        </div>
        <div>
          {steps.map((step, i) => (
            <div key={i} data-pin-step className="ccd-pin-step" {...(i === 0 ? { "data-active": "" } : {})}>
              {step}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
