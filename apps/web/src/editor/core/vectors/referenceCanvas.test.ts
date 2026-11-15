import { describe, expect, it } from "vitest";
import { checkUnit, firstMismatch, loadVectors } from "./harness";
import {
  NEW_PROJECT_BOX,
  adoptNewProjectReferenceCanvas,
  exportReferenceCanvas,
  referenceCanvasFor,
  sanitizedReferenceBox,
} from "../math/referenceCanvas";
import { newProject, parseProject, ProjectDecodeError, serializeProject, type Size } from "../model";

type Input =
  | { kind: "newProjectBox" }
  | { kind: "canvas"; box: Size; aspect: number }
  | { kind: "sanitized"; box: Size }
  | { kind: "exportReference"; box: Size | null; preview: Size; output: Size };

describe("reference canvas golden vectors (Studio 2e)", () => {
  it("referenceCanvas — box, canvas, sanitizer, exporter canvas", () => {
    checkUnit<Input>("referenceCanvas", (i) => {
      switch (i.kind) {
        case "newProjectBox":
          return NEW_PROJECT_BOX;
        case "canvas":
          return referenceCanvasFor(i.box, i.aspect);
        case "sanitized":
          return sanitizedReferenceBox(i.box);
        case "exportReference":
          return exportReferenceCanvas(i.box, i.preview, i.output);
      }
    });
  });

  it("referenceCanvasDecode — parse+serialize equals Swift decode+encode; errors match", () => {
    const file = loadVectors<{ label: string; json: unknown }, Record<string, unknown>>("referenceCanvasDecode");
    const failures: string[] = [];
    for (const c of file.cases) {
      const label = c.input.label;
      if (c.output.error === true) {
        try {
          parseProject(c.input.json);
          failures.push(`${label}: Swift rejects this project but the web parsed it`);
        } catch (e) {
          if (!(e instanceof ProjectDecodeError)) failures.push(`${label}: threw ${(e as Error).message}`);
        }
        continue;
      }
      let web: Record<string, unknown>;
      try {
        web = serializeProject(parseProject(c.input.json), { includeExtra: false });
      } catch (e) {
        failures.push(`${label}: Swift decodes this project but the web threw ${(e as Error).message}`);
        continue;
      }
      // Written only when set — exactly where Swift's encodeIfPresent writes it.
      if ("referenceCanvasSize" in web !== "referenceCanvasSize" in c.output) {
        failures.push(`${label}: key presence differs (web ${"referenceCanvasSize" in web}, Swift ${"referenceCanvasSize" in c.output})`);
        continue;
      }
      const m = firstMismatch(web, c.output);
      if (m) failures.push(`${label}: ${m}`);
    }
    expect(failures, failures.join("\n")).toEqual([]);
    expect(file.cases.length).toBeGreaterThan(10);
  });
});

describe("reference canvas — creation rule", () => {
  it("newProject() (= Project.init) never stamps a box; creation sites do", () => {
    const p = newProject({ name: "t" });
    expect(p.referenceCanvasSize).toBeUndefined();
    expect("referenceCanvasSize" in serializeProject(p)).toBe(false);
    adoptNewProjectReferenceCanvas(p);
    expect(serializeProject(p).referenceCanvasSize).toEqual([803, 330]);
    // The stamp is a copy — mutating it can never move the shared constant.
    p.referenceCanvasSize!.width = 1;
    expect(NEW_PROJECT_BOX.width).toBe(803);
  });
});
