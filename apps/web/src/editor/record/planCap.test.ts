import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { FREE_RECORDING_SECONDS, cappedByPlan, effectiveLimit } from "./planCap";

const api = readFileSync(fileURLToPath(new URL("../../../../api/src/lib/plans.ts", import.meta.url)), "utf8");

describe("the Free recording cap", () => {
  it("is the API's FREE_RECORDING_SECONDS (apps/api/src/lib/plans.ts)", () => {
    expect(api).toContain(`export const FREE_RECORDING_SECONDS = ${FREE_RECORDING_SECONDS};`);
    expect(FREE_RECORDING_SECONDS).toBe(300);
  });

  it("caps a personal take at 5 minutes, keeping a shorter limit of the user's own", () => {
    expect(effectiveLimit(0, false)).toBe(300);
    expect(effectiveLimit(600, false)).toBe(300);
    expect(effectiveLimit(60, false)).toBe(60);
    expect(cappedByPlan(0, false)).toBe(true);
    expect(cappedByPlan(600, false)).toBe(true);
    expect(cappedByPlan(60, false)).toBe(false);
  });

  it("leaves a commercial plan's takes to the user's own limit", () => {
    expect(effectiveLimit(0, true)).toBe(0);
    expect(effectiveLimit(600, true)).toBe(600);
    expect(cappedByPlan(0, true)).toBe(false);
  });
});
