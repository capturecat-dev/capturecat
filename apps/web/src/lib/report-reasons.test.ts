import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { REMOVED_FALLBACK_MESSAGE, REPORT_DETAILS_MAX, REPORT_REASONS } from "./report-reasons";

const api = readFileSync(fileURLToPath(new URL("../../../api/src/lib/moderation.ts", import.meta.url)), "utf8");

describe("report reasons", () => {
  it("match the API's enum, order and labels exactly (apps/api/src/lib/moderation.ts)", () => {
    const list = api.match(/export const REPORT_REASONS = \[([\s\S]*?)\] as const;/)?.[1] ?? "";
    expect([...list.matchAll(/"([a-z]+)"/g)].map((m) => m[1])).toEqual(REPORT_REASONS.map((r) => r.value));
    for (const r of REPORT_REASONS) {
      expect(api).toContain(`${r.value}: "${r.label}"`);
    }
  });

  it("share the details limit and the removal message", () => {
    expect(api).toContain(`REPORT_DETAILS_MAX = ${REPORT_DETAILS_MAX}`);
    expect(api).toContain(`REMOVED_MESSAGE = "${REMOVED_FALLBACK_MESSAGE}"`);
  });
});
