/**
 * Port of Studio/Models/ReferenceCanvas.swift (Studio 2e) — locked by the
 * `referenceCanvas` vectors.
 *
 * Every point-sized setting (padding, corners, shadow, cursor, text, camera)
 * is authored in canvas points and the exporter scales it by
 * `outputSize / canvas`. A project carries a persisted reference BOX
 * (`Project.referenceCanvasSize`), and every renderer — the Mac editor at any
 * window size, the web stage at any slot size, the iOS stage, headless
 * exports — lays it out on the same canvas: the largest one of the output's
 * aspect inside the box. Editors draw that canvas and MAGNIFY it to their
 * stage. A project without a box (from before 2e) keeps the old rule: the live
 * editor canvas, or the output itself for a headless export.
 */
import type { Project, Size } from "../model/types";
import { letterboxRect } from "./aspectRatio";

/** `ReferenceCanvas.newProjectBox` — the Mac's default editor card (Phase 0
 * §3.4). Its canvas is 586.7×330 at 16:9. */
export const NEW_PROJECT_BOX: Size = Object.freeze({ width: 803, height: 330 });

/** `ReferenceCanvas.canvas(box:aspect:)` — the largest canvas of `aspect`
 * (w/h) inside `box`. */
export function referenceCanvasFor(box: Size, aspect: number): Size {
  const r = letterboxRect({ x: 0, y: 0, width: box.width, height: box.height }, aspect);
  return { width: r.width, height: r.height };
}

/** `ReferenceCanvas.sanitized(_:)` — the box when finite and positive, else null. */
export function sanitizedReferenceBox(box: Size | null | undefined): Size | null {
  if (!box) return null;
  const { width, height } = box;
  if (!Number.isFinite(width) || !Number.isFinite(height) || !(width > 0) || !(height > 0)) return null;
  return { width, height };
}

/** `Project.referenceCanvas(aspect:)` — the canvas a project with `box`
 * lays out on for an output of `aspect`; null without a usable box. */
export function projectReferenceCanvas(box: Size | null | undefined, aspect: number): Size | null {
  const b = sanitizedReferenceBox(box);
  if (!b || !(aspect > 0) || !Number.isFinite(aspect)) return null;
  return referenceCanvasFor(b, aspect);
}

/**
 * `Project.exportReferenceCanvas(outputSize:)` — the canvas the exporter scales
 * point-sized settings against for a file of `output`: the reference canvas;
 * without a box, `previewCanvas` (the live editor canvas) when it has a size,
 * else the output itself (headless, scale 1).
 */
export function exportReferenceCanvas(
  box: Size | null | undefined,
  previewCanvas: Size | null | undefined,
  output: Size,
): Size {
  if (output.height > 0) {
    const canvas = projectReferenceCanvas(box, output.width / output.height);
    if (canvas) return canvas;
  }
  if (previewCanvas && previewCanvas.width > 0 && previewCanvas.height > 0) return previewCanvas;
  return output;
}

/** `Project.adoptNewProjectReferenceCanvas()` — stamps a brand-new project.
 * Called where a recording or capture BECOMES a project (the web recorder's
 * publish, the iOS template), never by `newProject()` (= `Project.init`) or
 * the parser, so projects from before 2e keep rendering as they did. */
export function adoptNewProjectReferenceCanvas(project: Pick<Project, "referenceCanvasSize">): void {
  project.referenceCanvasSize = { ...NEW_PROJECT_BOX };
}
