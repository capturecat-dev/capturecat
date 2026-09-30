/**
 * Share-page annotation markers — the port of
 * `ExportSheetController.annotationMarkers(for:)`: the project's annotations
 * in OUTPUT-time seconds on the exporter's own SpeedTimeMap (trim range +
 * speed regions), so a marker points at the frame of the uploaded file that
 * the annotation covered in the editor. Text / callout annotations carry
 * their trimmed display text (≤ 120 characters) as the label.
 *
 * Wire shape: `apps/api/src/lib/upload-schemas.ts` → `MarkerSchema`.
 */
import { displayText } from "../math/annotationEffectMath";
import { smax, smin } from "../math/swift";
import type { Project } from "../model/types";
import { effectiveTrimEnd, effectiveTrimStart } from "../time/clips";
import { SpeedTimeMap } from "../time/speedTimeMap";

export interface ShareMarker {
  start: number;
  end: number;
  label?: string;
}

let segmenter: Intl.Segmenter | null = null;

/** `String(s.prefix(n))` — n grapheme clusters. */
function prefixGraphemes(s: string, n: number): string {
  segmenter ??= new Intl.Segmenter(undefined, { granularity: "grapheme" });
  const parts = Array.from(segmenter.segment(s), (p) => p.segment);
  return parts.length <= n ? s : parts.slice(0, n).join("");
}

/** `trimmingCharacters(in: .whitespacesAndNewlines)` */
function trimmed(s: string): string {
  return s.replace(/^[\p{Z}\t\n\v\f\r\u0085]+|[\p{Z}\t\n\v\f\r\u0085]+$/gu, "");
}

export function annotationMarkers(project: Project): ShareMarker[] {
  const trimStart = effectiveTrimStart(project);
  const trimEnd = smax(trimStart, effectiveTrimEnd(project));
  if (!(trimEnd > trimStart)) return [];
  const map = new SpeedTimeMap(trimStart, trimEnd, project.speedRegions);
  return project.annotations
    .filter((a) => a.endTime > trimStart && a.startTime < trimEnd)
    .sort((a, b) => a.startTime - b.startTime)
    .map((a) => {
      const marker: ShareMarker = {
        start: map.outputTime(smax(a.startTime, trimStart)),
        end: map.outputTime(smin(a.endTime, trimEnd)),
      };
      const label = trimmed(displayText(a));
      if (label.length > 0 && (a.type === "text" || a.type === "callout")) marker.label = prefixGraphemes(label, 120);
      return marker;
    });
}
