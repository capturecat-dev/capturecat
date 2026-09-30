/**
 * Share status — the Mac export sheet's share rows (ExportSheetController
 * `applyShareState`) and the project card's upload line (ProjectCardItem),
 * one component for the sheet and the top-bar Share popover:
 *
 *   exporting   "Exporting NN%…"            + progress bar
 *   uploading   "Uploading to share..."     + progress bar (springs)
 *   completing  "Finalizing share link..."
 *   done        <link>                      [Copy]
 *   failed      "Share failed: <message>"   [Retry]
 *
 * ShareButton is the top bar's key: its label follows the job (the card's
 * meta line), a click on an idle key starts a share, otherwise it opens the
 * popover with the rows above.
 */
import { useEffect, useRef, useState, useSyncExternalStore } from "react";

import type { ShareState } from "../../state/share";
import type { ShareCenter } from "../../state/shareCenter";
import { Button, InspectorButton, Popover, rectOf, type AnchorRect } from "../kit";

export function useShareState(center: ShareCenter | null): ShareState {
  return useSyncExternalStore(
    (fn) => center?.subscribe(fn) ?? (() => {}),
    () => center?.getState() ?? IDLE,
    () => IDLE,
  );
}

const IDLE: ShareState = { phase: "idle" };

function percent(p: number): number {
  return Math.round(Math.min(1, Math.max(0, p)) * 100);
}

export function SharePanel({
  state,
  onCopy,
  onRetry,
}: {
  state: ShareState;
  onCopy: () => Promise<boolean> | void;
  onRetry: () => void;
}) {
  const [copied, setCopied] = useState(false);
  useEffect(() => setCopied(false), [state]);
  if (state.phase === "idle") return null;
  const progress = state.phase === "uploading" || state.phase === "exporting" ? state.progress : null;
  const label =
    state.phase === "exporting"
      ? `Exporting ${percent(state.progress)}%…`
      : state.phase === "uploading"
        ? "Uploading to share..."
        : state.phase === "completing"
          ? "Finalizing share link..."
          : state.phase === "done"
            ? state.url
            : `Share failed: ${state.message}`;
  return (
    <div className="cc-share" aria-live="polite">
      <div className="cc-share__row">
        <span className="cc-caption cc-share__status" data-phase={state.phase} title={label}>
          {label}
        </span>
        {state.phase === "done" && (
          <InspectorButton
            onClick={async () => {
              const ok = await onCopy();
              if (ok !== false) setCopied(true);
            }}
          >
            {copied ? "Copied" : "Copy"}
          </InspectorButton>
        )}
        {state.phase === "failed" && <InspectorButton onClick={onRetry}>Retry</InspectorButton>}
      </div>
      {progress !== null && (
        <div
          className="cc-progress cc-share__progress cc-mat-recessed cc-mat-pill"
          role="progressbar"
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={percent(progress)}
        >
          <div className="cc-progress__clip" style={{ width: `${Math.min(1, Math.max(0, progress)) * 100}%` }}>
            <div className="cc-progress__fill cc-mat-raised cc-mat-short" />
          </div>
        </div>
      )}
    </div>
  );
}

/** The top bar's Share key + its status popover. */
export function ShareButton({ center, onShare }: { center: ShareCenter; onShare: () => void }) {
  const state = useShareState(center);
  const ref = useRef<HTMLSpanElement>(null);
  const [anchor, setAnchor] = useState<AnchorRect | null>(null);

  const label =
    state.phase === "exporting"
      ? `Exporting ${percent(state.progress)}%`
      : state.phase === "uploading"
        ? `Uploading ${percent(state.progress)}%`
        : state.phase === "completing"
          ? "Creating link…"
          : state.phase === "done"
            ? "Shared"
            : state.phase === "failed"
              ? "Share failed"
              : "Share";
  return (
    <span ref={ref} className="cc-share-key" data-phase={state.phase}>
      <Button
        variant="ghost"
        size="sm"
        symbol={state.phase === "done" ? "link" : state.phase === "failed" ? "exclamationmark.icloud" : "square.and.arrow.up"}
        title={state.phase === "idle" ? "Share a link to this video" : label}
        onClick={() => {
          // Starting here opens the status popover (the card's progress
          // line); a share started from the sheet shows there instead.
          if (state.phase === "idle") onShare();
          if (ref.current) setAnchor(anchor ? null : rectOf(ref.current));
        }}
      >
        {label}
      </Button>
      {anchor && state.phase !== "idle" && (
        <Popover anchor={anchor} align="end" onDismiss={() => setAnchor(null)} ignore={ref.current}>
          <div className="cc-share-pop">
            <SharePanel state={state} onCopy={() => center.copyLink()} onRetry={() => void center.retry()} />
            {(state.phase === "done" || state.phase === "failed") && (
              <div className="cc-share-pop__footer">
                <InspectorButton
                  onClick={() => {
                    setAnchor(null);
                    center.dismiss();
                  }}
                >
                  {state.phase === "done" ? "Done" : "Dismiss"}
                </InspectorButton>
                {state.phase === "done" && (
                  <InspectorButton
                    onClick={() => {
                      center.dismiss();
                      onShare();
                    }}
                  >
                    Share Again
                  </InspectorButton>
                )}
              </div>
            )}
          </div>
        </Popover>
      )}
    </span>
  );
}
