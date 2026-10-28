/**
 * WebMCP `share_project` / `share_status` — the browser twin of the Mac's
 * MCPServer+Share.swift + AgentShareBroker.swift. Same names, arguments,
 * states and result shape (the catalog's outputSchema), adapted to a tab:
 *
 *  - ASK FIRST (the owner's rule): every call shows the house AlertDialog
 *    (ui/kit/Alert — never window.confirm) naming the project, that an AI
 *    agent is asking, and who will be able to watch. Return does nothing
 *    and Allow arms after a beat, so only a deliberate click approves.
 *    Approval is per call; no argument can pre-grant it (unknown arguments
 *    are refused outright).
 *  - On Allow it runs the editor's own top-bar Share (state/shareCenter.ts →
 *    state/share.ts): export, upload, confirm, replace-in-place for a project
 *    shared before — with the approved privacy enforced by the upload.
 *  - It answers as soon as the user has decided, with a job id; the agent
 *    polls share_status until "done" (then shareUrl is the link).
 *
 * Nothing here deletes anything. Pure logic over an injected host, so the
 * confirm-then-share contract is unit-tested with the dialog mocked.
 */
import type { ShareState, ShareUploadResult, ShareVisibility } from "../state/share";
import type { AlertSpec } from "../ui/kit/Alert";
import type { ToolArgs, ToolHandler } from "./register";

export const SHARE_PRIVACY: readonly ShareVisibility[] = ["unlisted", "public", "private"];

/** The Mac's `ShareVisibility.summary`, word for word. */
export const VISIBILITY_SUMMARY: Record<ShareVisibility, string> = {
  unlisted: "Anyone with the link can watch. Not listed on your profile.",
  public: "Anyone with the link can watch, and it's listed on your public profile.",
  private: "Only you can watch it (signed in to CaptureCat).",
};

export const CONSENT_TITLE = "Allow an AI agent to share this project?";
export const CONSENT_ALLOW = "Allow";
export const CONSENT_DECLINE = "Don't Allow";
export const CONSENT_ARM_DELAY_MS = 600;

/** The slice of ShareCenter the tools drive (ShareCenter satisfies it). */
export interface ShareCenterLike {
  readonly isActive: boolean;
  getState(): ShareState;
  subscribe(fn: () => void): () => void;
  sharedURL(): string | null;
  shareProject(opts: { privacy?: ShareVisibility }): Promise<ShareUploadResult | null>;
}

export interface ShareToolHost {
  /** The house AlertDialog (`AlertPresenter.present`) → the chosen button index. */
  confirm(spec: AlertSpec): Promise<number>;
  /** The project open in this tab. */
  project(): { id: string; name: string } | null;
  center: ShareCenterLike;
}

export type ShareJobState =
  | "awaiting_approval"
  | "declined"
  | "refused"
  | "exporting"
  | "uploading"
  | "completing"
  | "done"
  | "failed"
  | "interrupted";

interface ShareJob {
  jobId: string;
  state: ShareJobState;
  projectId: string;
  projectName: string;
  privacy: ShareVisibility;
  progress?: number;
  shareUrl?: string;
  videoId?: string;
  error?: string;
  warning?: string;
  replacesExistingLink: boolean;
  updatedAt: string;
}

/** The consent dialog for one request. */
export function consentSpec(input: { projectName: string; privacy: ShareVisibility; existingLink: string | null }): AlertSpec {
  const details = [
    { label: "Project", value: input.projectName },
    { label: "Requested by", value: "An AI agent using this tab's WebMCP tools" },
    { label: "Who can watch", value: VISIBILITY_SUMMARY[input.privacy] },
  ];
  if (input.existingLink) {
    details.push({ label: "Existing link", value: `Replaces the video at ${input.existingLink} with this version.` });
  }
  return {
    title: CONSENT_TITLE,
    message:
      "An AI agent in this browser tab asked to upload this project to your CaptureCat account and create a share " +
      "link. Allowing applies to this request only.",
    details,
    buttons: [{ title: CONSENT_ALLOW, role: "primary" }, { title: CONSENT_DECLINE }],
    noDefault: true,
    armDelayMs: CONSENT_ARM_DELAY_MS,
  };
}

const TERMINAL: ReadonlySet<ShareJobState> = new Set(["declined", "refused", "done", "failed", "interrupted"]);

function noteFor(job: ShareJob): string {
  switch (job.state) {
    case "awaiting_approval":
      return "Waiting for the user to answer the request in this tab. Poll again in a few seconds.";
    case "declined":
      return "The user declined. Nothing was shared; don't retry unless the user asks.";
    case "refused":
      return "The editor couldn't ask the user (see error). Nothing was shared.";
    case "exporting":
      return "Approved — the editor is rendering the video (progress 0–1). Poll again.";
    case "uploading":
      return "Approved — uploading (progress 0–1). Poll again.";
    case "completing":
      return "Upload finished; the server is verifying it. Poll again.";
    case "done":
      return `Live. shareUrl is the link — ${VISIBILITY_SUMMARY[job.privacy]}`;
    case "failed":
      return "The share failed (see error). Nothing new is viewable; tell the user.";
    case "interrupted":
      return "The share stopped before finishing (see error).";
  }
}

function payload(job: ShareJob, note: string): Record<string, unknown> {
  const out: Record<string, unknown> = {
    jobId: job.jobId,
    state: job.state,
    projectId: job.projectId,
    projectName: job.projectName,
    privacy: job.privacy,
    replacesExistingLink: job.replacesExistingLink,
    updatedAt: job.updatedAt,
    note,
  };
  if (job.progress !== undefined) out.progress = Math.round(Math.max(0, Math.min(1, job.progress)) * 1000) / 1000;
  if (job.shareUrl !== undefined) out.shareUrl = job.shareUrl;
  if (job.videoId !== undefined) out.videoId = job.videoId;
  if (job.error !== undefined) out.error = job.error;
  if (job.warning !== undefined) out.warning = job.warning;
  return out;
}

function refuseUnknown(args: ToolArgs, allowed: string[], tool: string): void {
  const extra = Object.keys(args).filter((key) => !allowed.includes(key)).sort();
  if (extra.length === 0) return;
  throw new Error(
    `unknown argument(s): ${extra.join(", ")} — ${tool} takes ${allowed.join(" and ")} only.` +
      (tool === "share_project" ? " Approval can only come from the user's click in this tab." : ""),
  );
}

/**
 * The two handlers. `getHost` is read on every call (the editor wires the
 * share center after the tools register); jobs live in this closure — one
 * tab, one registry.
 */
export function createShareTools(
  getHost: () => ShareToolHost | null,
  opts: { newId?: () => string; now?: () => Date } = {},
): { share_project: ToolHandler; share_status: ToolHandler } {
  const newId = opts.newId ?? (() => crypto.randomUUID().toUpperCase());
  const now = opts.now ?? (() => new Date());
  const jobs = new Map<string, ShareJob>();

  const touch = (job: ShareJob, patch: Partial<ShareJob>): void => {
    Object.assign(job, patch, { updatedAt: now().toISOString() });
  };

  /** The editor's ShareState → the job (while this job is the running one). */
  const mirror = (job: ShareJob, state: ShareState): void => {
    if (TERMINAL.has(job.state)) return;
    switch (state.phase) {
      case "exporting":
        return touch(job, { state: "exporting", progress: state.progress });
      case "uploading":
        return touch(job, { state: "uploading", progress: state.progress });
      case "completing":
        return touch(job, { state: "completing", progress: 1 });
      default:
        return; // done / failed / idle land via the shareProject result
    }
  };

  const share_project: ToolHandler = async (args) => {
    refuseUnknown(args, ["project_id", "privacy"], "share_project");
    const rawPrivacy = args.privacy ?? "unlisted";
    if (typeof rawPrivacy !== "string" || !(SHARE_PRIVACY as readonly string[]).includes(rawPrivacy)) {
      throw new Error(`privacy must be one of: ${SHARE_PRIVACY.map((p) => `"${p}"`).join(", ")}`);
    }
    const privacy = rawPrivacy as ShareVisibility;
    const host = getHost();
    if (!host) throw new Error("sharing isn't ready in this tab yet — retry in a moment");
    const project = host.project();
    if (!project) throw new Error("the project is still loading — retry in a moment");
    const requested = args.project_id;
    if (typeof requested === "string" && requested !== "" && requested.toUpperCase() !== project.id.toUpperCase()) {
      throw new Error(
        `the web editor shares the project open in this tab (${project.id}) — open ${requested} in the editor to share it, or omit project_id`,
      );
    }
    if (host.center.isActive) {
      throw new Error(`A share of “${project.name}” is already in progress in this tab. Wait for it to finish, then try again.`);
    }

    const existingLink = host.center.sharedURL();
    const choice = await host.confirm(consentSpec({ projectName: project.name, privacy, existingLink }));
    if (choice !== 0) {
      throw new Error(`The user declined: “${project.name}” was not shared. Don't retry unless the user asks you to.`);
    }
    // The world may have moved while the dialog was up.
    if (host.center.isActive) {
      throw new Error(`A share of “${project.name}” is already in progress — nothing new was started.`);
    }

    const job: ShareJob = {
      jobId: newId(),
      state: "exporting",
      progress: 0,
      projectId: project.id,
      projectName: project.name,
      privacy,
      replacesExistingLink: existingLink !== null,
      updatedAt: now().toISOString(),
    };
    jobs.set(job.jobId, job);
    const center = host.center;
    const unsubscribe = center.subscribe(() => mirror(job, center.getState()));
    void center
      .shareProject({ privacy })
      .then((result) => {
        if (result) {
          touch(job, { state: "done", progress: 1, shareUrl: result.url, videoId: result.videoId, warning: result.warning });
          return;
        }
        const state = center.getState();
        if (state.phase === "failed") touch(job, { state: "failed", error: state.message });
        else touch(job, { state: "interrupted", error: "The share was cancelled in the editor before it finished." });
      })
      .catch((e: unknown) => touch(job, { state: "failed", error: e instanceof Error ? e.message : String(e) }))
      .finally(unsubscribe);

    return payload(
      job,
      "The user approved. The editor is exporting and uploading (the top bar shows progress). Poll share_status " +
        "{job_id} every few seconds; the link is live only once state is \"done\" — then report shareUrl to the user.",
    );
  };

  const share_status: ToolHandler = async (args) => {
    refuseUnknown(args, ["job_id"], "share_status");
    const jobId = args.job_id;
    if (typeof jobId !== "string" || jobId === "") throw new Error("missing job_id — the jobId share_project returned");
    const job = jobs.get(jobId) ?? jobs.get(jobId.toUpperCase());
    if (!job) throw new Error(`unknown job_id ${jobId} — share jobs live in the editor tab that started them`);
    return payload(job, noteFor(job));
  };

  return { share_project, share_status };
}
