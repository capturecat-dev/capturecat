/**
 * Upload allowance, decided from the plan row and nothing else.
 *
 * This is the ONLY place that turns `PlanLimits` + `PlanFeatures` into an
 * allow/deny for a cloud upload. The four upload routes (presign, complete,
 * replace, replace-complete) all call `checkUploadAllowance`, so raising a
 * tier's storage in the admin console changes what every one of them accepts
 * on the next request — no constants, no deploy.
 *
 * Pure: no D1, no R2, no Hono. Tested in `upload-policy.test.ts`.
 */

import type { PlanFeatures, PlanLimits } from "./plans";

export interface UploadAttempt {
  /** Declared size at presign time, or the R2-verified size at complete. */
  fileSizeBytes: number;
  /** 0 when not known or not applicable (complete re-checks skip it). */
  durationSeconds?: number;
  /** Sum of every ready version the user owns, before this upload. */
  usedBytes: number;
  /** Shares started today. Omit to skip the daily cap (complete, replace). */
  uploadsToday?: number;
  /** The file goes to the user's own bucket (migration 0029): CaptureCat
   *  stores none of it, so the total-storage cap does not apply. Per-file
   *  size, duration and the daily cap still do. */
  ownBucket?: boolean;
}

export type UploadVerdict =
  | { ok: true }
  | {
      ok: false;
      status: 402 | 413 | 429;
      body: { error: string; code: string } & Record<string, unknown>;
    };

const GiB = 1024 * 1024 * 1024;
const MiB = 1024 * 1024;

/** "10 GB", "1.5 GB", "250 MB", "512 B" — binary units, labelled the way the
 *  pricing page labels them. */
export function formatBytes(bytes: number): string {
  if (bytes >= GiB) {
    const gb = bytes / GiB;
    return `${Number.isInteger(gb) ? gb : gb.toFixed(1)} GB`;
  }
  if (bytes >= MiB) {
    const mb = bytes / MiB;
    return `${Number.isInteger(mb) ? mb : mb.toFixed(1)} MB`;
  }
  return `${bytes} B`;
}

export function formatDuration(seconds: number): string {
  if (seconds >= 60 && seconds % 60 === 0) {
    const m = seconds / 60;
    return `${m} minute${m === 1 ? "" : "s"}`;
  }
  return `${seconds} second${seconds === 1 ? "" : "s"}`;
}

/** The storage-cap denial, shared with the atomic accept path in the upload
 *  routes (which decides the cap inside SQL and needs the same body). */
export function storageDeniedBody(
  plan: { limits: PlanLimits },
  usedBytes: number,
): { error: string; code: string } & Record<string, unknown> {
  const limit = plan.limits.maxTotalStorageBytes;
  return {
    error: `Storage limit reached (${formatBytes(limit)}). Delete shared videos or old versions before uploading more.`,
    code: "storage_limit_reached",
    usedBytes,
    limitBytes: limit,
    remainingBytes: Math.max(0, limit - usedBytes),
  };
}

export function checkUploadAllowance(
  plan: { displayName: string; features: PlanFeatures; limits: PlanLimits },
  attempt: UploadAttempt,
): UploadVerdict {
  const { features, limits } = plan;

  if (!features.cloudShare) {
    return {
      ok: false,
      status: 402,
      body: {
        error: `Cloud sharing is not included in the ${plan.displayName} plan. Upgrade to share this video.`,
        code: "cloud_share_required",
        plan: plan.displayName,
      },
    };
  }

  // A zero cap on any of these means the plan carries no upload allowance
  // at all — say so, rather than "max 0 B".
  if ((!attempt.ownBucket && limits.maxTotalStorageBytes <= 0) || limits.maxFileSizeBytes <= 0) {
    return {
      ok: false,
      status: 402,
      body: {
        error: `The ${plan.displayName} plan has no cloud storage. Upgrade to share this video.`,
        code: "no_storage_allowance",
        plan: plan.displayName,
      },
    };
  }

  if (attempt.fileSizeBytes > limits.maxFileSizeBytes) {
    return {
      ok: false,
      status: 413,
      body: {
        error: `File too large (max ${formatBytes(limits.maxFileSizeBytes)})`,
        code: "file_too_large",
        fileSizeBytes: attempt.fileSizeBytes,
        maxFileSizeBytes: limits.maxFileSizeBytes,
      },
    };
  }

  const duration = attempt.durationSeconds ?? 0;
  if (limits.maxDurationSeconds > 0 && duration > limits.maxDurationSeconds) {
    return {
      ok: false,
      status: 413,
      body: {
        error: `Recording too long (max ${formatDuration(limits.maxDurationSeconds)})`,
        code: "recording_too_long",
        durationSeconds: duration,
        maxDurationSeconds: limits.maxDurationSeconds,
      },
    };
  }

  if (!attempt.ownBucket && attempt.usedBytes + attempt.fileSizeBytes > limits.maxTotalStorageBytes) {
    return { ok: false, status: 413, body: storageDeniedBody(plan, attempt.usedBytes) };
  }

  if (attempt.uploadsToday !== undefined) {
    if (limits.maxUploadsPerDay <= 0) {
      return {
        ok: false,
        status: 402,
        body: {
          error: `The ${plan.displayName} plan has no daily upload allowance. Upgrade to share this video.`,
          code: "no_upload_allowance",
          plan: plan.displayName,
        },
      };
    }
    if (attempt.uploadsToday >= limits.maxUploadsPerDay) {
      return {
        ok: false,
        status: 429,
        body: {
          error: `Daily upload limit reached (${limits.maxUploadsPerDay} per day)`,
          code: "daily_upload_limit",
          uploadsToday: attempt.uploadsToday,
          maxUploadsPerDay: limits.maxUploadsPerDay,
        },
      };
    }
  }

  return { ok: true };
}
