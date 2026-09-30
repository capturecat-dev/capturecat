import { describe, expect, it } from "vitest";
import { loadVectors, numbersMatch } from "./harness";
import {
  newAnnotation,
  newBlurRegion,
  newCameraLayoutRegion,
  newFocusRegion,
  newHighlightRegion,
  newProject,
  newSpeedRegion,
  newSubtitleSegment,
  newTiltRegion,
  newVoiceOverClip,
  newZoomRegion,
  defaultExportSettings,
  defaultProjectSettings,
  DEFAULT_COLORS,
  parseProject,
  ProjectDecodeError,
  serializeProject,
} from "../model";
import type { AnnotationType, Project } from "../model";

/**
 * STRICT structural equality (same key sets, exact strings/bools, numbers
 * within the vector tolerance). Returns the first mismatch path or null.
 * `ignore(path)` skips paths whose Swift value is nondeterministic.
 */
function strictMismatch(
  actual: unknown,
  expected: unknown,
  path: string,
  ignore: (path: string) => boolean = () => false,
): string | null {
  if (ignore(path)) return null;
  if (typeof expected === "number") {
    return typeof actual === "number" && numbersMatch(actual, expected) ? null : `${path}: ${actual} != ${expected}`;
  }
  if (expected === null || typeof expected !== "object") {
    return actual === expected ? null : `${path}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`;
  }
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || actual.length !== expected.length) return `${path}: array shape differs`;
    for (let i = 0; i < expected.length; i++) {
      const m = strictMismatch(actual[i], expected[i], `${path}[${i}]`, ignore);
      if (m) return m;
    }
    return null;
  }
  if (!actual || typeof actual !== "object" || Array.isArray(actual)) return `${path}: expected object`;
  const ek = Object.keys(expected).sort();
  const ak = Object.keys(actual).sort();
  const missing = ek.filter((k) => !ak.includes(k));
  const extra = ak.filter((k) => !ek.includes(k));
  if (missing.length || extra.length) {
    return `${path}: keys differ (web missing ${JSON.stringify(missing)}, web extra ${JSON.stringify(extra)})`;
  }
  for (const k of ek) {
    const m = strictMismatch(
      (actual as Record<string, unknown>)[k],
      (expected as Record<string, unknown>)[k],
      `${path}.${k}`,
      ignore,
    );
    if (m) return m;
  }
  return null;
}

/** The keys the generator injects as "unknown to Swift" (see WebVectors+Model.swift). */
const INJECTED_UNKNOWN_KEYS = new Set(["futureKey", "autoPauseEnabled", "x_web_note"]);

/** Every injected unknown key in `input` that sits inside an object Swift kept. */
function collectUnknown(input: unknown, swift: unknown, path: string, out: Array<[string, unknown]>) {
  if (Array.isArray(input) && Array.isArray(swift)) {
    input.forEach((v, i) => collectUnknown(v, swift[i], `${path}[${i}]`, out));
    return;
  }
  if (
    input &&
    typeof input === "object" &&
    !Array.isArray(input) &&
    swift &&
    typeof swift === "object" &&
    !Array.isArray(swift)
  ) {
    for (const [k, v] of Object.entries(input)) {
      if (INJECTED_UNKNOWN_KEYS.has(k) && !(k in swift)) out.push([`${path}.${k}`, v]);
      else if (k in swift) collectUnknown(v, (swift as Record<string, unknown>)[k], `${path}.${k}`, out);
    }
  }
}

function getPath(root: unknown, path: string): unknown {
  const parts = path.match(/[^.[\]]+/g) ?? [];
  let cur: unknown = root;
  for (const p of parts) cur = (cur as Record<string, unknown>)?.[p];
  return cur;
}

const FIXED_ID = "00000000-0000-4000-8000-000000000001";

describe("model golden vectors", () => {
  it("modelDefaults", () => {
    const file = loadVectors<{ kind: string; type?: string; name?: string }, unknown>("modelDefaults");
    const failures: string[] = [];
    for (const c of file.cases) {
      let web: unknown;
      const kind = c.input.kind;
      const base = newProject({ id: FIXED_ID, duration: 0, createdAt: 0 });
      switch (kind) {
        case "ProjectSettings":
          web = serializeProject({ ...base, settings: defaultProjectSettings() }).settings;
          break;
        case "ExportSettings":
          web = serializeProject({ ...base, settings: { ...defaultProjectSettings(), exportSettings: defaultExportSettings() } })
            .settings as Record<string, unknown>;
          web = (web as Record<string, unknown>).exportSettings;
          break;
        case "Project": {
          const o = serializeProject(base);
          delete o.createdAt;
          web = o;
          break;
        }
        case "ProjectWithCamera": {
          const o = serializeProject(newProject({ id: FIXED_ID, duration: 0, createdAt: 0, cameraVideoURL: "file:///tmp/camera.mov" }));
          delete o.createdAt;
          web = o;
          break;
        }
        case "ZoomRegion":
          web = { ...newZoomRegion(0, 1, FIXED_ID) };
          break;
        case "TiltRegion":
          web = serializeProject({ ...base, tiltRegions: [newTiltRegion(0, 1, FIXED_ID)] }).tiltRegions;
          web = (web as unknown[])[0];
          break;
        case "BlurRegion":
          web = newBlurRegion(0, 1, FIXED_ID);
          break;
        case "HighlightRegion":
          web = newHighlightRegion(0, 1, FIXED_ID);
          break;
        case "FocusRegion":
          web = newFocusRegion(0, 1, FIXED_ID);
          break;
        case "CameraLayoutRegion":
          web = newCameraLayoutRegion(0, 1, FIXED_ID);
          break;
        case "VideoSpeedRegion":
          web = newSpeedRegion(0, 1, FIXED_ID);
          break;
        case "VoiceOverClip":
          web = newVoiceOverClip("vo.m4a", 0, 1, { id: FIXED_ID });
          break;
        case "SubtitleSegment":
          web = newSubtitleSegment(0, 1, "Hi", FIXED_ID);
          break;
        case "Annotation":
          web = (serializeProject({ ...base, annotations: [newAnnotation(c.input.type as AnnotationType, 0, 1, FIXED_ID)] })
            .annotations as unknown[])[0];
          break;
        case "NSColor":
          web = DEFAULT_COLORS[c.input.name as keyof typeof DEFAULT_COLORS];
          break;
        default:
          failures.push(`unknown kind ${kind}`);
          continue;
      }
      const m = strictMismatch(web, c.output, kind, (p) => p === "Project.cameraVideoURL" || p === "ProjectWithCamera.cameraVideoURL");
      if (m) failures.push(m);
    }
    expect(failures, failures.join("\n")).toEqual([]);
  });

  it("projectDecode — parse+serialize equals Swift decode+encode; errors match; unknown keys survive", () => {
    const file = loadVectors<{ json: unknown; mutations: string[] }, Record<string, unknown>>("projectDecode");
    const failures: string[] = [];
    let ok = 0;
    let errors = 0;
    let unknownKept = 0;
    file.cases.forEach((c, i) => {
      const label = `case ${i} [${c.input.mutations.join("; ")}]`;
      if (c.output.error === true) {
        errors++;
        try {
          parseProject(c.input.json);
          failures.push(`${label}: Swift rejects this project but the web parsed it`);
        } catch (e) {
          if (!(e instanceof ProjectDecodeError)) failures.push(`${label}: threw non-decode error ${(e as Error).message}`);
        }
        return;
      }
      let project: Project;
      try {
        project = parseProject(c.input.json);
      } catch (e) {
        failures.push(`${label}: Swift decodes this project but the web threw ${(e as Error).message}`);
        return;
      }
      // Swift generates a random id for a CameraLayoutRegion without one.
      const input = c.input.json as Record<string, unknown>;
      const ignore = (p: string) => {
        const m = /^\.cameraLayoutRegions\[(\d+)\]\.id$/.exec(p);
        if (!m) return false;
        const raw = (input.cameraLayoutRegions as Array<Record<string, unknown>> | undefined)?.[Number(m[1])]?.id;
        return raw === undefined || raw === null;
      };
      const web = serializeProject(project, { includeExtra: false });
      const m = strictMismatch(web, c.output, "", ignore);
      if (m) {
        failures.push(`${label}: ${m}`);
        return;
      }
      // Lossless: every key Swift does not know must come back verbatim.
      const unknown: Array<[string, unknown]> = [];
      collectUnknown(c.input.json, c.output, "", unknown);
      const full = serializeProject(project);
      for (const [p, v] of unknown) {
        const got = getPath(full, p);
        if (JSON.stringify(got) !== JSON.stringify(v)) failures.push(`${label}: unknown key ${p} not preserved`);
        else unknownKept++;
      }
      // Idempotence: parse(serialize(parse(x))) == parse(x).
      const again = serializeProject(parseProject(JSON.parse(JSON.stringify(full))));
      const m2 = strictMismatch(again, full, "", ignore);
      if (m2) failures.push(`${label}: not idempotent: ${m2}`);
      ok++;
    });
    expect(failures.slice(0, 8), `${failures.length} failures\n${failures.slice(0, 8).join("\n")}`).toEqual([]);
    expect(ok + errors).toBe(file.cases.length);
    expect(errors).toBeGreaterThan(0);
    expect(unknownKept).toBeGreaterThan(0);
  });
});
