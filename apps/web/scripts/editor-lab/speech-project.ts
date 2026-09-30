/**
 * Writes the synthetic speech project's project.json with the core model's
 * own defaults (a complete Mac-decodable document). Called by
 * make-speech-project.sh:  npx vite-node --config vitest.config.ts scripts/editor-lab/speech-project.ts -- <dir> <UUID> <duration>
 */
import { writeFileSync } from "node:fs";
import { join } from "node:path";

import { newProject, serializeProjectText } from "../../src/editor/core/model";

const [dir, id, duration] = process.argv.slice(2).filter((a) => a !== "--");
if (!dir || !id || !duration) throw new Error("usage: speech-project.ts <dir> <UUID> <duration>");
const d = Number(duration);
const p = newProject({ id, name: "Speech demo", duration: d, videoURL: "recording.mov" });
p.trimStart = 0;
p.trimEnd = d;
p.settings.showSubtitles = true;
writeFileSync(join(dir, "project.json"), serializeProjectText(p));
