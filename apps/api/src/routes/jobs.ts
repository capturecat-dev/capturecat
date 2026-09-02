import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { userRateLimit } from "../lib/entitlement";
import { generateId } from "../lib/id";
import type { ShareJobRow } from "../share-jobs";

/**
 * Background share-upload jobs, backed by the per-user ShareJobsDO.
 *
 * The desktop app registers a job right after it gets a presigned upload URL
 * (POST /api/upload/video), reports progress while the file streams to R2,
 * and completes/fails the job at the end. GET is shared by the app's projects
 * page and the web dashboard, so both surfaces render identical state.
 */
export const jobRoutes = new Hono<{
  Bindings: Env;
  Variables: Variables;
}>();

const UUID_RE =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

function jobsStub(c: { env: Env; get: (k: "user") => { uid: string } }) {
  return c.env.SHARE_JOBS.getByName(c.get("user").uid);
}

function publicJob(row: ShareJobRow) {
  return {
    jobId: row.id,
    videoId: row.video_id,
    projectId: row.project_id,
    projectName: row.project_name,
    fileName: row.file_name,
    fileSizeBytes: row.file_size_bytes,
    state: row.state,
    progress: row.progress,
    shareUrl: row.share_url,
    error: row.error,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

jobRoutes.get("/upload/jobs", requireAuth, async (c) => {
  const jobs = await jobsStub(c).listJobs();
  return c.json({ jobs: jobs.map(publicJob) });
});

jobRoutes.post(
  "/upload/jobs",
  requireAuth,
  userRateLimit({ limit: 30, windowSec: 60, scope: "jobs" }),
  async (c) => {
    const body = await c.req.json<{
      videoId?: string;
      projectId?: string;
      projectName?: string;
      fileName?: string;
      fileSizeBytes?: number;
    }>();
    if (!body.videoId || !body.fileName) {
      return c.json({ error: "videoId and fileName are required" }, 400);
    }
    const job = await jobsStub(c).createJob({
      id: generateId(16),
      videoId: String(body.videoId).slice(0, 64),
      projectId:
        typeof body.projectId === "string" && UUID_RE.test(body.projectId)
          ? body.projectId.toUpperCase()
          : null,
      projectName:
        typeof body.projectName === "string"
          ? body.projectName.slice(0, 120)
          : null,
      fileName: String(body.fileName).slice(0, 200),
      fileSizeBytes:
        typeof body.fileSizeBytes === "number" && body.fileSizeBytes > 0
          ? Math.floor(body.fileSizeBytes)
          : 0,
    });
    return c.json({ job: publicJob(job) });
  }
);

jobRoutes.post("/upload/jobs/:jobId/progress", requireAuth, async (c) => {
  const body = await c.req.json<{ progress?: number; completing?: boolean }>();
  const stub = jobsStub(c);
  const jobId = c.req.param("jobId");
  const job = body.completing
    ? await stub.markCompleting(jobId)
    : await stub.updateProgress(jobId, Number(body.progress ?? 0));
  if (!job) return c.json({ error: "Job not found" }, 404);
  return c.json({ job: publicJob(job) });
});

jobRoutes.post("/upload/jobs/:jobId/complete", requireAuth, async (c) => {
  const body = await c.req.json<{ shareUrl?: string }>();
  if (!body.shareUrl) return c.json({ error: "shareUrl is required" }, 400);
  const job = await jobsStub(c).completeJob(
    c.req.param("jobId"),
    String(body.shareUrl).slice(0, 500)
  );
  if (!job) return c.json({ error: "Job not found" }, 404);
  return c.json({ job: publicJob(job) });
});

jobRoutes.post("/upload/jobs/:jobId/fail", requireAuth, async (c) => {
  const body = await c.req.json<{ error?: string }>();
  const job = await jobsStub(c).failJob(
    c.req.param("jobId"),
    typeof body.error === "string" ? body.error : "upload failed"
  );
  if (!job) return c.json({ error: "Job not found" }, 404);
  return c.json({ job: publicJob(job) });
});
