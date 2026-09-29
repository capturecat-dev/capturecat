import { describe, expect, it } from "vitest";
import { checkUploadAllowance, formatBytes, formatDuration } from "./upload-policy";
import { parseStoredFeatures, parseStoredLimits } from "./plans";

const GiB = 1024 ** 3;
const MiB = 1024 ** 2;

function plan(overrides: { features?: Record<string, boolean>; limits?: Record<string, number> } = {}) {
  return {
    displayName: "Test",
    features: parseStoredFeatures({ cloudShare: true, ...overrides.features }),
    limits: parseStoredLimits({
      maxTotalStorageBytes: 10 * GiB,
      maxFileSizeBytes: 1 * GiB,
      maxDurationSeconds: 1800,
      maxUploadsPerDay: 10,
      ...overrides.limits,
    }),
  };
}

function deny(v: ReturnType<typeof checkUploadAllowance>) {
  if (v.ok) throw new Error("expected a denial");
  return v;
}

describe("checkUploadAllowance", () => {
  it("allows an upload inside every cap", () => {
    const v = checkUploadAllowance(plan(), {
      fileSizeBytes: 100 * MiB,
      durationSeconds: 600,
      usedBytes: 2 * GiB,
      uploadsToday: 3,
    });
    expect(v).toEqual({ ok: true });
  });

  it("denies with 402 when the plan has no cloudShare, before any limit", () => {
    const v = deny(
      checkUploadAllowance(plan({ features: { cloudShare: false } }), {
        fileSizeBytes: 1,
        usedBytes: 0,
        uploadsToday: 0,
      }),
    );
    expect(v.status).toBe(402);
    expect(v.body.code).toBe("cloud_share_required");
    expect(v.body.error).toContain("Test plan");
  });

  it("denies with 402 when storage or file-size cap is 0 (the free row)", () => {
    const free = {
      displayName: "Free",
      features: parseStoredFeatures({ cloudShare: true }),
      limits: parseStoredLimits({ maxDurationSeconds: 300 }),
    };
    const v = deny(checkUploadAllowance(free, { fileSizeBytes: 1, usedBytes: 0 }));
    expect(v.status).toBe(402);
    expect(v.body.code).toBe("no_storage_allowance");
  });

  it("file size: 413 with the plan's own cap in the message", () => {
    const v = deny(
      checkUploadAllowance(plan({ limits: { maxFileSizeBytes: 512 * MiB } }), {
        fileSizeBytes: 512 * MiB + 1,
        usedBytes: 0,
      }),
    );
    expect(v.status).toBe(413);
    expect(v.body.code).toBe("file_too_large");
    expect(v.body.error).toBe("File too large (max 512 MB)");
    expect(v.body.maxFileSizeBytes).toBe(512 * MiB);
  });

  it("duration: 413 above the cap, and 0 means no duration cap", () => {
    const v = deny(checkUploadAllowance(plan(), { fileSizeBytes: 1, durationSeconds: 1801, usedBytes: 0 }));
    expect(v.status).toBe(413);
    expect(v.body.error).toBe("Recording too long (max 30 minutes)");

    const unlimited = checkUploadAllowance(plan({ limits: { maxDurationSeconds: 0 } }), {
      fileSizeBytes: 1,
      durationSeconds: 100_000,
      usedBytes: 0,
    });
    expect(unlimited.ok).toBe(true);
  });

  it("storage: 413 with used/limit/remaining so the client can explain", () => {
    const v = deny(
      checkUploadAllowance(plan({ limits: { maxFileSizeBytes: 4 * GiB } }), { fileSizeBytes: 3 * GiB, usedBytes: 8 * GiB }),
    );
    expect(v.status).toBe(413);
    expect(v.body.code).toBe("storage_limit_reached");
    expect(v.body.error).toContain("(10 GB)");
    expect(v.body.usedBytes).toBe(8 * GiB);
    expect(v.body.limitBytes).toBe(10 * GiB);
    expect(v.body.remainingBytes).toBe(2 * GiB);
  });

  it("storage: exactly filling the cap is allowed; one byte over is not", () => {
    const p = plan({ limits: { maxFileSizeBytes: 4 * GiB } });
    expect(checkUploadAllowance(p, { fileSizeBytes: 2 * GiB, usedBytes: 8 * GiB }).ok).toBe(true);
    expect(checkUploadAllowance(p, { fileSizeBytes: 2 * GiB + 1, usedBytes: 8 * GiB }).ok).toBe(false);
  });

  it("raising the plan's storage in the row lifts the cap with no other change", () => {
    const attempt = { fileSizeBytes: 1 * GiB, usedBytes: 9.5 * GiB };
    expect(checkUploadAllowance(plan(), attempt).ok).toBe(false);
    expect(checkUploadAllowance(plan({ limits: { maxTotalStorageBytes: 100 * GiB } }), attempt).ok).toBe(true);
  });

  it("daily cap: 429 at the cap, skipped when uploadsToday is omitted", () => {
    const v = deny(checkUploadAllowance(plan(), { fileSizeBytes: 1, usedBytes: 0, uploadsToday: 10 }));
    expect(v.status).toBe(429);
    expect(v.body.error).toBe("Daily upload limit reached (10 per day)");
    expect(checkUploadAllowance(plan(), { fileSizeBytes: 1, usedBytes: 0, uploadsToday: 9 }).ok).toBe(true);
    // complete/replace pass no counter and must not trip it.
    expect(checkUploadAllowance(plan({ limits: { maxUploadsPerDay: 0 } }), { fileSizeBytes: 1, usedBytes: 0 }).ok).toBe(true);
  });

  it("daily cap of 0 with a counter present is 402, not 429", () => {
    const v = deny(
      checkUploadAllowance(plan({ limits: { maxUploadsPerDay: 0 } }), { fileSizeBytes: 1, usedBytes: 0, uploadsToday: 0 }),
    );
    expect(v.status).toBe(402);
    expect(v.body.code).toBe("no_upload_allowance");
  });
});

describe("formatting", () => {
  it("formatBytes uses binary units the way the pricing page does", () => {
    expect(formatBytes(10 * GiB)).toBe("10 GB");
    expect(formatBytes(1.5 * GiB)).toBe("1.5 GB");
    expect(formatBytes(250 * MiB)).toBe("250 MB");
    expect(formatBytes(512)).toBe("512 B");
  });
  it("formatDuration prefers whole minutes", () => {
    expect(formatDuration(1800)).toBe("30 minutes");
    expect(formatDuration(60)).toBe("1 minute");
    expect(formatDuration(90)).toBe("90 seconds");
  });
});
