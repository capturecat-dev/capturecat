/**
 * NSStackView spacing, as the Mac inspector boxes resolve it (pure — see
 * layout.tsx). `addRow(_, attached: true)` sets a custom spacing AFTER the
 * row before it (a property of that previous row, kept while the attached
 * row is hidden); each visible row then sits at the custom spacing after
 * the previous VISIBLE row.
 */
export interface SpacedRow {
  show?: boolean;
  attached?: boolean;
}

/** Margin above each row (the first visible row gets 0). Hidden rows get
 *  the margin they would have if shown (used while they animate out). */
export function rowMargins(rows: readonly SpacedRow[], gap = 16, attachedGap = 6): number[] {
  let prevVisible = -1;
  return rows.map((row, i) => {
    const margin = prevVisible < 0 ? 0 : rows[prevVisible + 1]?.attached ? attachedGap : gap;
    if (row.show !== false) prevVisible = i;
    return margin;
  });
}
