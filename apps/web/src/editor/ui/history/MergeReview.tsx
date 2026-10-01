/**
 * Merge Review (docs/project-history.md §1 "Concurrent edits"): a 409 whose
 * three-way merge hit STRUCTURAL conflicts. Each conflict gets a Mine /
 * Theirs segmented control defaulting to the last writer; the same-field
 * clashes the most recent edit already settled are listed collapsed.
 * Nothing saves until "Apply Merge" (store.applyReview → one undo step +
 * a `merge` checkpoint save). Keep mine / Load theirs stays only as the
 * no-base fallback (EditorPage's top-bar accessory).
 */
import { useMemo, useState } from "react";

import type { Side } from "../../core/merge";
import { describeAutoResolved, describeConflict, useHistory, type HistoryController } from "../../state/history";
import { useEditorStore, type EditorStore } from "../../state/store";
import { Button, Reveal, Segmented, SFIcon } from "../kit";

const SIDES: readonly Side[] = ["mine", "theirs"];

export function MergeReview({ history, store }: { history: HistoryController; store: EditorStore }) {
  const review = useEditorStore(store, (s) => s.review);
  const version = useEditorStore(store, (s) => s.version);
  const author = useHistory(history, (s) => s.reviewAuthor);
  const [showAuto, setShowAuto] = useState(false);
  const [stale, setStale] = useState(false);
  const docs = useMemo(
    () => store.reviewDocuments(),
    // The documents change with every re-merge / edit during review.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [store, review, version],
  );
  if (!review || !docs) {
    return (
      <div className="cc-history__page">
        <div className="cc-hempty">
          <SFIcon name="checkmark.icloud" size={20} weight="regular" />
          <div className="cc-hempty__title">Nothing to review</div>
        </div>
      </div>
    );
  }
  const them = author ?? "the other editor";
  const lastWriter = review.mineWins ? "Mine" : "Theirs";
  return (
    <div className="cc-history__page" data-merge-review="">
      <div className="cc-hreview__intro">
        You and {them} both changed this project. Choose whose version wins for each change below — nothing is saved until you apply.
      </div>
      {stale && (
        <div className="cc-hreview__intro" role="status">
          Your latest edits raised another conflict — it’s listed below.
        </div>
      )}
      {review.conflicts.map((c) => {
        const d = describeConflict(c, docs, them);
        const index = SIDES.indexOf(c.resolution);
        return (
          <div key={c.id} className="cc-hconflict cc-mat-matte" data-conflict-id={c.id} data-kind={c.kind}>
            <div>
              <div className="cc-hconflict__title">{d.title}</div>
              <div className="cc-hconflict__detail">{d.detail}</div>
            </div>
            <Segmented
              segments={["Mine", "Theirs"]}
              selectedIndex={index < 0 ? 0 : index}
              size="sm"
              ariaLabel={`${d.title}: keep mine or theirs`}
              onChange={(i) => store.setReviewChoice(c.id, SIDES[i])}
            />
            <div className="cc-hconflict__pick">
              {c.resolution === "mine" ? d.mine : d.theirs}
              {c.resolution === c.defaultResolution ? ` · ${lastWriter} edited last` : ""}
            </div>
          </div>
        );
      })}
      {review.autoResolved.length > 0 && (
        <div className="cc-hauto">
          <span
            className="cc-hauto__toggle"
            role="button"
            tabIndex={0}
            aria-expanded={showAuto}
            onClick={() => setShowAuto((v) => !v)}
            onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && setShowAuto((v) => !v)}
          >
            <SFIcon name="chevron.right" size={8} weight="semibold" />
            {review.autoResolved.length} same-setting edit{review.autoResolved.length === 1 ? "" : "s"} went to the most recent change
          </span>
          <Reveal show={showAuto}>
            <ul>
              {review.autoResolved.map((a) => (
                <li key={`${a.kind}:${a.path}`}>
                  {describeAutoResolved(a.path, [docs.mine, docs.theirs, docs.base])} — {a.winner === "mine" ? "yours" : "theirs"}
                </li>
              ))}
            </ul>
          </Reveal>
        </div>
      )}
      <div style={{ display: "flex", justifyContent: "flex-end", padding: "12px 4px 0" }}>
        <Button
          variant="primary"
          onClick={() => {
            const ok = store.applyReview();
            setStale(!ok);
          }}
        >
          Apply Merge
        </Button>
      </div>
    </div>
  );
}
