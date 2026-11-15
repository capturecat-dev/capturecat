/**
 * The iOS app creates cloud projects (iPhone screen takes, screenshots) from
 * apps/ios/Core/ProjectTemplate.json: the Mac's `Project(videoURL:…)` defaults
 * as THIS model serializes them, stamped like every NEW project with the
 * Studio 2e reference canvas (newProject + adoptNewProjectReferenceCanvas +
 * serializeProjectText — the same path the web recorder publishes with). The iOS app fills in id, name,
 * createdAt, media refs and duration and never invents a default of its own,
 * so a new phone project opens on the Mac and the web exactly like one made
 * there.
 *
 * This suite locks the template to the model: if a default changes here, it
 * fails until the template is regenerated —
 *   UPDATE_IOS_TEMPLATE=1 npx vitest run src/editor/core/vectors/iosProjectTemplate.test.ts
 */
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { adoptNewProjectReferenceCanvas } from "../math/referenceCanvas";
import { newProject, serializeProjectText } from "../model";

const TEMPLATE = resolve(__dirname, "../../../../../ios/Core/ProjectTemplate.json");
const PLACEHOLDER_ID = "00000000-0000-0000-0000-000000000000";

function expectedTemplate(): string {
  const project = newProject({
    id: PLACEHOLDER_ID,
    name: "Untitled Recording",
    createdAt: 0,
    videoURL: `file:///CaptureCat/Projects/${PLACEHOLDER_ID}/recording.mp4`,
    cursorDataURL: null,
    cameraVideoURL: null,
    cameraTimeOffset: 0,
    duration: 0,
    recordingSourceKind: "device",
  });
  adoptNewProjectReferenceCanvas(project);
  return serializeProjectText(project) + "\n";
}

describe("iOS project template", () => {
  it("matches newProject() exactly", () => {
    const expected = expectedTemplate();
    if (process.env.UPDATE_IOS_TEMPLATE === "1") writeFileSync(TEMPLATE, expected);
    expect(readFileSync(TEMPLATE, "utf8")).toBe(expected);
  });
});
