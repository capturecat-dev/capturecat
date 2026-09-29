import { describe, expect, it } from "vitest";
import {
  FEATURE_KEYS,
  LIMIT_KEYS,
  PlanFeaturesInputSchema,
  PlanLimitsInputSchema,
  parseStoredFeatures,
  parseStoredLimits,
} from "./plans";

describe("stored plan JSON (lenient, deny-by-default)", () => {
  it("garbage JSON denies every feature and zeroes every limit", () => {
    const f = parseStoredFeatures("{not json");
    for (const k of FEATURE_KEYS) expect(f[k]).toBe(false);
    const l = parseStoredLimits("{not json");
    for (const k of LIMIT_KEYS) expect(l[k]).toBe(0);
  });

  it("a row that predates a key denies only that key", () => {
    const f = parseStoredFeatures('{"cloudShare":true,"comments":true}');
    expect(f.cloudShare).toBe(true);
    expect(f.comments).toBe(true);
    expect(f.sso).toBe(false);
    expect(f.teams).toBe(false);
  });

  it("a wrong-typed value denies that key and keeps the others", () => {
    const f = parseStoredFeatures({ cloudShare: "true", comments: 1, teams: true });
    expect(f.cloudShare).toBe(false);
    expect(f.comments).toBe(false);
    expect(f.teams).toBe(true);
  });

  it("unknown keys are dropped rather than carried along", () => {
    const f = parseStoredFeatures({ cloudShare: true, unlimitedEverything: true });
    expect("unlimitedEverything" in f).toBe(false);
  });

  it("limits: negative, fractional, string, and huge values all read as 0", () => {
    const l = parseStoredLimits({
      maxTotalStorageBytes: -1,
      maxFileSizeBytes: 1.5,
      maxDurationSeconds: "1800",
      maxUploadsPerDay: Number.MAX_SAFE_INTEGER + 2,
      maxScreenshotsPerMonth: 250,
    });
    expect(l.maxTotalStorageBytes).toBe(0);
    expect(l.maxFileSizeBytes).toBe(0);
    expect(l.maxDurationSeconds).toBe(0);
    expect(l.maxUploadsPerDay).toBe(0);
    expect(l.maxScreenshotsPerMonth).toBe(250);
  });

  it("arrays and null are treated as empty objects", () => {
    expect(parseStoredLimits("[1,2]").maxTotalStorageBytes).toBe(0);
    expect(parseStoredFeatures(null).cloudShare).toBe(false);
  });

  it("the pro seed row parses to exactly what the migration wrote", () => {
    const l = parseStoredLimits(
      '{"maxTotalStorageBytes":10737418240,"maxFileSizeBytes":1073741824,"maxDurationSeconds":1800,"maxUploadsPerDay":10}',
    );
    expect(l).toEqual({
      maxTotalStorageBytes: 10 * 1024 ** 3,
      maxFileSizeBytes: 1024 ** 3,
      maxDurationSeconds: 1800,
      maxUploadsPerDay: 10,
      maxScreenshotsPerMonth: 0,
    });
  });
});

describe("admin plan input (strict)", () => {
  it("fills missing keys with deny/zero", () => {
    const f = PlanFeaturesInputSchema.parse({ cloudShare: true });
    expect(f.cloudShare).toBe(true);
    expect(f.sso).toBe(false);
    const l = PlanLimitsInputSchema.parse({ maxTotalStorageBytes: 5 });
    expect(l.maxTotalStorageBytes).toBe(5);
    expect(l.maxUploadsPerDay).toBe(0);
  });

  it("rejects an unknown key instead of writing a flag nothing reads", () => {
    expect(PlanFeaturesInputSchema.safeParse({ cloudshare: true }).success).toBe(false);
    expect(PlanLimitsInputSchema.safeParse({ maxStorage: 1 }).success).toBe(false);
  });

  it("rejects wrong types instead of quietly denying at runtime", () => {
    expect(PlanFeaturesInputSchema.safeParse({ cloudShare: "yes" }).success).toBe(false);
    expect(PlanLimitsInputSchema.safeParse({ maxFileSizeBytes: -1 }).success).toBe(false);
    expect(PlanLimitsInputSchema.safeParse({ maxFileSizeBytes: 1.5 }).success).toBe(false);
  });
});
