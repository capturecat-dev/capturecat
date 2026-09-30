/**
 * The Mac panes' stack layout, reproduced exactly.
 *
 * Every Mac pane is an NSStackView of InspectorSectionBoxes (24pt apart),
 * and every box an NSStackView of rows (16pt apart). `addRow(_, attached:
 * true)` sets a 6pt CUSTOM spacing AFTER the row before it — a property of
 * the PREVIOUS row that survives when the attached row is hidden. NSStackView
 * then spaces each visible row by the custom spacing after the previous
 * VISIBLE row. That is why, on the Mac, Mirror Camera sits 6pt under Shape
 * whenever the (attached) orientation chips are hidden, and Padding sits 6pt
 * under the placement pad while Reset to Center is hidden. `RowStack` applies
 * the same rule, so the web lands on the same pixels.
 *
 * Visibility changes animate (Reveal): growth bounces at the pushed edge.
 */
import type { ReactNode } from "react";

import { Reveal } from "../kit";
import { rowMargins } from "./stackSpacing";

export interface StackRow {
  key: string;
  node: ReactNode;
  /** isHidden = !show. Rows the Mac never adds are simply left out. */
  show?: boolean;
  /** Added with `addRow(_, attached: true)`. */
  attached?: boolean;
}

export function RowStack({ rows, gap = 16, attachedGap = 6 }: { rows: readonly (StackRow | false | null | undefined)[]; gap?: number; attachedGap?: number }) {
  const list = rows.filter((r): r is StackRow => !!r);
  const margins = rowMargins(list, gap, attachedGap);
  return (
    <>
      {list.map((row, i) => (
        <Reveal key={row.key} show={row.show !== false} marginTop={margins[i]}>
          {row.node}
        </Reveal>
      ))}
    </>
  );
}

/** InspectorSectionBox: hairline (not on the first visible box) + 18pt, the
 *  uppercase tracked header + 10pt, then the rows. */
export function Box({ title, first, rows }: { title?: string; first?: boolean; rows: readonly (StackRow | false | null | undefined)[] }) {
  return (
    <section className="cc-section" data-first={first || undefined}>
      <div className="cc-section__rule" />
      {title && <div className="cc-section__header">{title}</div>}
      <div className="cc-box__body">
        <RowStack rows={rows} />
      </div>
    </section>
  );
}

export interface PaneItem {
  key: string;
  show?: boolean;
  render: (first: boolean) => ReactNode;
}

/** The pane's own 24pt stack of boxes; the first VISIBLE box drops its
 *  hairline (InspectorSectionBox.updateHairlineVisibility). */
export function PaneStack({ items }: { items: readonly (PaneItem | false | null | undefined)[] }) {
  const list = items.filter((i): i is PaneItem => !!i);
  const firstVisible = list.findIndex((i) => i.show !== false);
  let seen = false;
  return (
    <div className="cc-panestack">
      {list.map((item, i) => {
        const visible = item.show !== false;
        const margin = seen ? 24 : 0;
        if (visible) seen = true;
        return (
          <Reveal key={item.key} show={visible} marginTop={margin}>
            {item.render(i === firstVisible)}
          </Reveal>
        );
      })}
    </div>
  );
}
