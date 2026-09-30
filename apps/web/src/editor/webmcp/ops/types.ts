import type { Project } from "../../core/model";

/** A JSON object as the tools receive and return it. */
export type JSONObject = Record<string, unknown>;

/**
 * What the pure op cores need from their host (the editor store in the
 * browser, the parity harness in Node).
 */
export interface OpContext {
  /** A fresh id in Swift's `UUID().uuidString` form (UPPERCASE 8-4-4-4-12). */
  newId(): string;
  /**
   * `AutoZoomApplier.apply(to: project, zoomLevel:)` — mutates `project` in
   * place (replacing earlier `isAuto` zooms) and returns how many regions it
   * created (0 = no cursor data / nothing zoom-worthy; project untouched).
   * Only called when `project.cursorDataURL` is set.
   */
  autoZoom(project: Project, zoomLevel: number | null): number;
  /**
   * `StillMotionApplier.apply(to: project)` — the image-capture Motion tour.
   * Mutates in place, returns the number of regions created. Only called for
   * image captures without cursor data.
   */
  stillMotion(project: Project): number;
}

/**
 * `MCPServer.EditCore` — `(project, args) throws -> result`. `project` is a
 * MUTABLE draft mutated in place (Swift's `Project` is a reference type); a
 * throw means the caller must discard the draft (nothing is committed).
 */
export type EditCore = (project: Project, args: JSONObject, ctx: OpContext) => JSONObject;
