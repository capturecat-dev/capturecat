/**
 * The repo-root skills/ folder holds a copy of every SKILL.md served at
 * /.well-known/agent-skills/, so `npx skills add capturecat-dev/capturecat`
 * (and the skills.sh directory, which lists what that CLI installs) finds
 * them. AGENT_SKILLS is the only source: this suite fails when a copy drifts,
 * and rewrites the copies when run with UPDATE_SKILL_FILES=1
 * (`npm run skills:sync`).
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { AGENT_SKILLS } from "./agent-skills";
import { SITE_URL } from "./site-url";

const SKILLS_DIR = fileURLToPath(new URL("../../../../skills/", import.meta.url));
const skillFile = (name: string) => `${SKILLS_DIR}${name}/SKILL.md`;
const UPDATE = process.env.UPDATE_SKILL_FILES === "1";

describe("SKILL.md front matter", () => {
  it("keeps name and description as plain YAML scalars", () => {
    // Front matter is written unquoted. An unquoted ": " or " #" makes it
    // invalid YAML (js-yaml: "bad indentation of a mapping entry"), and skill
    // loaders then drop the skill. Reword the description instead.
    for (const skill of AGENT_SKILLS) {
      for (const value of [skill.name, skill.description]) {
        expect(value, `${skill.name}: ${value}`).not.toMatch(/^[-?:,[\]{}#&*!|>'"%@`\s]|: | #|:$|\s$|\n/);
      }
    }
  });
});

describe("repo skills/ folder", () => {
  it("holds every served SKILL.md byte for byte", () => {
    // The copies are public; they must carry production links, never a dev URL.
    expect(SITE_URL).toBe("https://capturecat.so");
    for (const skill of AGENT_SKILLS) {
      const file = skillFile(skill.name);
      if (UPDATE) {
        mkdirSync(`${SKILLS_DIR}${skill.name}`, { recursive: true });
        writeFileSync(file, skill.markdown);
      }
      expect(existsSync(file), `${file} is missing: run npm run skills:sync`).toBe(true);
      expect(readFileSync(file, "utf8"), `${file} is stale: run npm run skills:sync`).toBe(skill.markdown);
    }
  });

  it("holds no skill that is no longer served", () => {
    const served = new Set(AGENT_SKILLS.map((s) => s.name));
    const stale = readdirSync(SKILLS_DIR, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && !served.has(entry.name))
      .map((entry) => entry.name);
    expect(stale, "delete these folders from skills/").toEqual([]);
  });
});
