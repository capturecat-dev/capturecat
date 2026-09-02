import { DurableObject } from "cloudflare:workers";
import type { Env } from "./types";

/**
 * Per-user background share-upload job tracker.
 *
 * One instance per user (`getByName(userId)`), so isolation and listing are
 * structural — a request routed through requireAuth can only ever reach its
 * own jobs. The desktop app creates a job when a share upload starts, streams
 * progress into it, and completes/fails it; the projects page in the app and
 * the web dashboard both read the same job rows, so they show the same
 * progress.
 *
 * The upload bytes do NOT flow through here — the file goes Mac → R2 via the
 * presigned URL exactly as before. This object is the coordination record.
 */
export interface ShareJobRow {
  // Index signature satisfies sql.exec's Record<string, SqlStorageValue> bound.
  [key: string]: string | number | null;
  id: string;
  video_id: string;
  project_id: string | null;
  project_name: string | null;
  file_name: string;
  file_size_bytes: number;
  state: "uploading" | "completing" | "done" | "failed";
  progress: number;
  share_url: string | null;
  error: string | null;
  created_at: number;
  updated_at: number;
}

/** Uploads with no progress report for this long are marked failed. */
const STALE_UPLOAD_MS = 6 * 60 * 60 * 1000;
/** Finished/failed rows are swept after this long. */
const RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
/** Housekeeping alarm cadence while any job rows exist. */
const SWEEP_INTERVAL_MS = 60 * 60 * 1000;

export class ShareJobsDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS jobs (
          id TEXT PRIMARY KEY,
          video_id TEXT NOT NULL,
          project_id TEXT,
          project_name TEXT,
          file_name TEXT NOT NULL,
          file_size_bytes INTEGER NOT NULL DEFAULT 0,
          state TEXT NOT NULL,
          progress REAL NOT NULL DEFAULT 0,
          share_url TEXT,
          error TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      `);
    });
  }

  async createJob(input: {
    id: string;
    videoId: string;
    projectId: string | null;
    projectName: string | null;
    fileName: string;
    fileSizeBytes: number;
  }): Promise<ShareJobRow> {
    const now = Date.now();
    this.ctx.storage.sql.exec(
      `INSERT INTO jobs (id, video_id, project_id, project_name, file_name,
         file_size_bytes, state, progress, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 'uploading', 0, ?, ?)`,
      input.id, input.videoId, input.projectId, input.projectName,
      input.fileName, input.fileSizeBytes, now, now
    );
    await this.ensureAlarm();
    return this.getJob(input.id)!;
  }

  getJob(id: string): ShareJobRow | null {
    const rows = this.ctx.storage.sql
      .exec<ShareJobRow>("SELECT * FROM jobs WHERE id = ?", id)
      .toArray();
    return rows[0] ?? null;
  }

  listJobs(): ShareJobRow[] {
    return this.ctx.storage.sql
      .exec<ShareJobRow>("SELECT * FROM jobs ORDER BY created_at DESC LIMIT 50")
      .toArray();
  }

  /** Progress only ever moves forward; a done/failed job is immutable. */
  updateProgress(id: string, progress: number): ShareJobRow | null {
    this.ctx.storage.sql.exec(
      `UPDATE jobs SET progress = MAX(progress, ?), updated_at = ?
       WHERE id = ? AND state = 'uploading'`,
      Math.min(1, Math.max(0, progress)), Date.now(), id
    );
    return this.getJob(id);
  }

  markCompleting(id: string): ShareJobRow | null {
    this.ctx.storage.sql.exec(
      `UPDATE jobs SET state = 'completing', progress = 1, updated_at = ?
       WHERE id = ? AND state = 'uploading'`,
      Date.now(), id
    );
    return this.getJob(id);
  }

  completeJob(id: string, shareUrl: string): ShareJobRow | null {
    this.ctx.storage.sql.exec(
      `UPDATE jobs SET state = 'done', progress = 1, share_url = ?, updated_at = ?
       WHERE id = ? AND state IN ('uploading', 'completing')`,
      shareUrl, Date.now(), id
    );
    return this.getJob(id);
  }

  failJob(id: string, error: string): ShareJobRow | null {
    this.ctx.storage.sql.exec(
      `UPDATE jobs SET state = 'failed', error = ?, updated_at = ?
       WHERE id = ? AND state IN ('uploading', 'completing')`,
      error.slice(0, 500), Date.now(), id
    );
    return this.getJob(id);
  }

  /** Sweep: stale uploads → failed; old finished rows → deleted. */
  async alarm(): Promise<void> {
    const now = Date.now();
    this.ctx.storage.sql.exec(
      `UPDATE jobs SET state = 'failed', error = 'upload stalled', updated_at = ?
       WHERE state IN ('uploading', 'completing') AND updated_at < ?`,
      now, now - STALE_UPLOAD_MS
    );
    this.ctx.storage.sql.exec(
      "DELETE FROM jobs WHERE state IN ('done', 'failed') AND updated_at < ?",
      now - RETENTION_MS
    );
    const remaining = this.ctx.storage.sql
      .exec<{ n: number }>("SELECT COUNT(*) AS n FROM jobs")
      .one().n;
    if (remaining > 0) {
      await this.ctx.storage.setAlarm(now + SWEEP_INTERVAL_MS);
    }
  }

  private async ensureAlarm(): Promise<void> {
    if ((await this.ctx.storage.getAlarm()) === null) {
      await this.ctx.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
    }
  }
}
