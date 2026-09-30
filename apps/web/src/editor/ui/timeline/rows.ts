/**
 * Lane row layout — ports of TimelineCanvasView.effectsRowAssignment /
 * effectsSpans (EFFECTS sub-rows, capped at 3, the PANEL grows) and
 * annotateRowLayout (ANNOTATE: every overlap cluster stacks into full-height
 * sub-rows; the lane band grows and the timeline SCROLLS vertically).
 */
import { M } from "./metrics";
import type { AnnotateBlock, TimelineSnapshot } from "./types";

export interface Span {
  key: string;
  start: number;
  end: number;
}

/** Greedy interval colouring: lowest free sub-row, capped at maxEffectsRows. */
export function effectsRowAssignment(spans: readonly Span[]): { rows: Map<string, number>; rowCount: number } {
  const rows = new Map<string, number>();
  const rowEnds: number[] = [];
  const sorted = [...spans].sort((a, b) => a.start - b.start);
  for (const span of sorted) {
    const free = rowEnds.findIndex((end) => span.start >= end - 0.0001);
    if (free >= 0) {
      rows.set(span.key, free);
      rowEnds[free] = Math.max(rowEnds[free], span.end);
    } else if (rowEnds.length < M.maxEffectsRows) {
      rows.set(span.key, rowEnds.length);
      rowEnds.push(span.end);
    } else {
      const last = M.maxEffectsRows - 1;
      rows.set(span.key, last);
      rowEnds[last] = Math.max(rowEnds[last], span.end);
    }
  }
  return { rows, rowCount: Math.max(1, rowEnds.length) };
}

export function effectsSpans(snapshot: TimelineSnapshot): Span[] {
  const spans: Span[] = snapshot.effects.map((e) => ({ key: e.key, start: e.start, end: e.end }));
  if (snapshot.intro && snapshot.intro.end > snapshot.intro.start) {
    spans.push({ key: "intro-chip", start: snapshot.intro.start, end: snapshot.intro.end });
  }
  if (snapshot.curtain && snapshot.curtain.end > snapshot.curtain.start) {
    spans.push({ key: "curtain-chip", start: snapshot.curtain.start, end: snapshot.curtain.end });
  }
  return spans;
}

export function effectsRowCount(snapshot: TimelineSnapshot): number {
  return effectsRowAssignment(effectsSpans(snapshot)).rowCount;
}

/** Draw order: earlier-starting first, so later ones draw on top. */
export function orderedAnnotations(items: readonly AnnotateBlock[]): AnnotateBlock[] {
  return [...items].sort((a, b) => a.start - b.start);
}

/**
 * Sub-row layout for concurrent annotations: greedy interval partitioning
 * per overlap CLUSTER, so isolated annotations keep the full lane and only
 * overlapping ones stack.
 */
export function annotateRowLayout(ordered: readonly AnnotateBlock[]): Map<string, { row: number; rows: number }> {
  const layout = new Map<string, { row: number; rows: number }>();
  let rowEnds: number[] = [];
  let assignments: Array<[string, number]> = [];
  let clusterMaxEnd = -Infinity;

  const flush = () => {
    for (const [id, row] of assignments) layout.set(id, { row, rows: rowEnds.length });
    assignments = [];
    rowEnds = [];
  };

  for (const item of ordered) {
    if (rowEnds.length && item.start >= clusterMaxEnd - 0.0001) flush();
    const free = rowEnds.findIndex((end) => end <= item.start + 0.0001);
    if (free >= 0) {
      rowEnds[free] = item.end;
      assignments.push([item.id, free]);
    } else {
      rowEnds.push(item.end);
      assignments.push([item.id, rowEnds.length - 1]);
    }
    clusterMaxEnd = Math.max(clusterMaxEnd, item.end);
  }
  flush();
  return layout;
}

export function annotateRowCount(layout: Map<string, { row: number; rows: number }>): number {
  let max = 1;
  for (const v of layout.values()) max = Math.max(max, v.rows);
  return max;
}
