/**
 * PNG export of a still capture — the port of `StillImageExporter`
 * (apps/macos/CaptureCat/Services/StillImageExporter.swift). The Mac renders
 * the PNG with the REAL video exporter over a settled micro clip and lifts
 * its last frame; the web renders the same frame with the same passes:
 *
 *   clone → trimEnd = min(duration, effectiveTrimStart + 0.2), no clip
 *   segments / split points / speed regions, intro slide + curtain unveil off
 *   → the micro clip's frame at `max(0, duration − 0.01)` (the last sample at
 *   or before it — `AVAssetImageGenerator` with zero after-tolerance).
 *
 * The export sheet offers PNG only for image-treatment stills
 * (`isImageCapture && stillTreatment == .image`), defaulting to it unless the
 * project `hasTimedEffects`.
 */
import { parseProject, serializeProject } from "../model";
import type { Project } from "../model/types";
import { hasTimedEffects, isImageCapture } from "../model/helpers";
import { effectiveTrimStart } from "../time/clips";
import { exportFrameSeconds } from "./staticSpans";

/** `StillImageExporter.microClipDuration` */
export const STILL_MICRO_CLIP_DURATION = 0.2;

/** The clone `exportPNG` renders: the settled micro clip at the head of the trim. */
export function stillExportProject(p: Project): Project {
  const start = effectiveTrimStart(p);
  return {
    ...p,
    trimEnd: Math.min(p.duration, start + STILL_MICRO_CLIP_DURATION),
    videoClipSegments: [],
    splitPoints: [],
    speedRegions: [],
    settings: { ...p.settings, introSlideStyle: "Off", curtainUnveilCorner: "Off" },
  };
}

/**
 * `stillExportProject` on a raw project.json (lossless: parse → clone edits →
 * serialize). A document the core model cannot parse gets the same edits on
 * its raw keys, so the renderer still draws the settled frame.
 */
export function stillExportDocument(doc: Record<string, unknown>): Record<string, unknown> {
  try {
    return serializeProject(stillExportProject(parseProject(doc)));
  } catch {
    const num = (v: unknown, d: number) => (typeof v === "number" && Number.isFinite(v) ? v : d);
    const duration = num(doc.duration, 0);
    const start = Math.max(0, num(doc.trimStart, 0));
    const settings = (doc.settings && typeof doc.settings === "object" ? doc.settings : {}) as Record<string, unknown>;
    return {
      ...doc,
      trimEnd: Math.min(duration, start + STILL_MICRO_CLIP_DURATION),
      videoClipSegments: [],
      splitPoints: [],
      speedRegions: [],
      settings: { ...settings, introSlideStyle: "Off", curtainUnveilCorner: "Off" },
    };
  }
}

/**
 * The export frame `lastFrame(of:)` returns for a micro clip of `duration`
 * output seconds at `fps`: the last frame whose PTS (the exporter's
 * CMTime-truncated frame time) is ≤ max(0, duration − 0.01).
 */
export function stillFrameIndex(duration: number, fps: number): number {
  const count = Math.max(1, Math.ceil(Math.max(0, duration) * Math.max(1, Math.trunc(fps))));
  const target = Math.max(0, duration - 0.01);
  let i = count - 1;
  while (i > 0 && exportFrameSeconds(i, fps) > target) i--;
  return i;
}

/** The sheet's Image (PNG) | Video (MP4) row exists (`isImageCapture && stillTreatment == .image`). */
export function offersImageExport(p: Project): boolean {
  return isImageCapture(p) && p.stillTreatment === "image";
}

/** The Type row's default: PNG unless any effect only reads as motion. */
export function defaultsToImageExport(p: Project): boolean {
  return offersImageExport(p) && !hasTimedEffects(p);
}
