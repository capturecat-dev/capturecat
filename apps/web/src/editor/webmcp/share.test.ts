import { describe, expect, it, vi } from "vitest";

import catalog from "./catalog.generated.json";
import { registerEditorTools, webCatalog, type ModelContextToolDescriptor } from "./register";
import {
  CONSENT_ALLOW,
  CONSENT_DECLINE,
  CONSENT_TITLE,
  VISIBILITY_SUMMARY,
  createShareTools,
  type ShareCenterLike,
  type ShareToolHost,
} from "./share";
import type { ShareState, ShareUploadResult, ShareVisibility } from "../state/share";
import type { AlertSpec } from "../ui/kit/Alert";

const PROJECT = { id: "1F0C2D8E-6A55-4C1B-9D33-0D8D3C1E7B10", name: "Checkout flow demo" };

/** A ShareCenter stand-in: scripted states, a share the test resolves. */
function fakeCenter(opts: { sharedURL?: string | null; active?: boolean } = {}) {
  let state: ShareState = { phase: "idle" };
  const listeners = new Set<() => void>();
  let finish: ((r: ShareUploadResult | null) => void) | null = null;
  const calls: Array<{ privacy?: ShareVisibility }> = [];
  const center: ShareCenterLike & {
    calls: typeof calls;
    set(s: ShareState): void;
    resolve(r: ShareUploadResult | null): Promise<void>;
  } = {
    get isActive() {
      return opts.active === true || ["exporting", "uploading", "completing"].includes(state.phase);
    },
    getState: () => state,
    subscribe(fn) {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },
    sharedURL: () => opts.sharedURL ?? null,
    shareProject(o) {
      calls.push(o);
      center.set({ phase: "exporting", progress: 0 });
      return new Promise((resolve) => {
        finish = resolve;
      });
    },
    calls,
    set(s) {
      state = s;
      for (const fn of listeners) fn();
    },
    async resolve(r) {
      finish?.(r);
      await new Promise((r2) => setTimeout(r2, 0));
    },
  };
  return center;
}

function host(center: ShareCenterLike, answer: number) {
  const confirm = vi.fn(async (_spec: AlertSpec) => answer);
  const h: ShareToolHost = { confirm, project: () => PROJECT, center };
  return { host: h, confirm };
}

const fixedTools = (h: ShareToolHost | null) =>
  createShareTools(() => h, { newId: () => "JOB-1", now: () => new Date("2026-10-28T12:00:00Z") });

const signal = new AbortController().signal;

describe("share_project — ask first, then the editor's Share", () => {
  it("shows the house dialog naming the project, the agent and the visibility; Return can't approve", async () => {
    const center = fakeCenter({ sharedURL: "https://capturecat.so/share/abc1234567" });
    const { host: h, confirm } = host(center, 1);
    await expect(fixedTools(h).share_project({ privacy: "public" }, signal)).rejects.toThrow(/declined/);
    expect(confirm).toHaveBeenCalledTimes(1);
    const spec = confirm.mock.calls[0][0];
    expect(spec.title).toBe(CONSENT_TITLE);
    expect(spec.buttons).toEqual([{ title: CONSENT_ALLOW, role: "primary" }, { title: CONSENT_DECLINE }]);
    expect(spec.noDefault).toBe(true);
    expect(spec.armDelayMs).toBeGreaterThan(0);
    const details = Object.fromEntries((spec.details ?? []).map((d) => [d.label, d.value]));
    expect(details.Project).toBe(PROJECT.name);
    expect(details["Requested by"]).toMatch(/AI agent/);
    expect(details["Who can watch"]).toBe(VISIBILITY_SUMMARY.public);
    expect(details["Existing link"]).toContain("abc1234567");
  });

  it("Don't Allow → refusal and nothing is shared", async () => {
    const center = fakeCenter();
    const { host: h } = host(center, 1);
    await expect(fixedTools(h).share_project({}, signal)).rejects.toThrow(/was not shared/);
    expect(center.calls).toEqual([]);
  });

  it("Allow → the editor's share runs with the approved privacy; share_status walks to done", async () => {
    const center = fakeCenter();
    const { host: h, confirm } = host(center, 0);
    const tools = fixedTools(h);
    const started = (await tools.share_project({ project_id: PROJECT.id.toLowerCase(), privacy: "private" }, signal)) as Record<string, unknown>;
    expect(confirm).toHaveBeenCalledTimes(1);
    expect(center.calls).toEqual([{ privacy: "private" }]);
    expect(started).toMatchObject({ jobId: "JOB-1", state: "exporting", projectId: PROJECT.id, privacy: "private" });
    expect(String(started.note)).toMatch(/share_status/);

    center.set({ phase: "uploading", progress: 0.5 });
    expect(await tools.share_status({ job_id: "JOB-1" }, signal)).toMatchObject({ state: "uploading", progress: 0.5 });

    await center.resolve({ url: "https://capturecat.so/share/abc1234567", videoId: "abc1234567" });
    expect(await tools.share_status({ job_id: "JOB-1" }, signal)).toMatchObject({
      state: "done",
      progress: 1,
      shareUrl: "https://capturecat.so/share/abc1234567",
      videoId: "abc1234567",
      privacy: "private",
    });
    // A later share by the user in the same tab never rewrites a finished job.
    center.set({ phase: "uploading", progress: 0.1 });
    expect(await tools.share_status({ job_id: "JOB-1" }, signal)).toMatchObject({ state: "done" });
  });

  it("defaults to unlisted", async () => {
    const center = fakeCenter();
    const { host: h, confirm } = host(center, 0);
    await fixedTools(h).share_project({}, signal);
    expect(center.calls).toEqual([{ privacy: "unlisted" }]);
    const details = Object.fromEntries((confirm.mock.calls[0][0].details ?? []).map((d) => [d.label, d.value]));
    expect(details["Who can watch"]).toBe(VISIBILITY_SUMMARY.unlisted);
  });

  it("a failed share reports failed with the editor's error", async () => {
    const center = fakeCenter();
    const { host: h } = host(center, 0);
    const tools = fixedTools(h);
    await tools.share_project({}, signal);
    center.set({ phase: "failed", message: "You must be signed in to share videos." });
    await center.resolve(null);
    expect(await tools.share_status({ job_id: "JOB-1" }, signal)).toMatchObject({
      state: "failed",
      error: "You must be signed in to share videos.",
    });
  });

  it("refuses — without asking — what it can't do", async () => {
    const center = fakeCenter();
    const { host: h, confirm } = host(center, 0);
    const tools = fixedTools(h);
    await expect(tools.share_project({ approved: true }, signal)).rejects.toThrow(/Approval can only come from the user's click/);
    await expect(tools.share_project({ privacy: "everyone" }, signal)).rejects.toThrow(/privacy must be one of/);
    await expect(tools.share_project({ project_id: "SOMETHING-ELSE" }, signal)).rejects.toThrow(/open in this tab/);
    const busy = fakeCenter({ active: true });
    await expect(fixedTools(host(busy, 0).host).share_project({}, signal)).rejects.toThrow(/already in progress/);
    await expect(fixedTools(null).share_project({}, signal)).rejects.toThrow(/isn't ready/);
    expect(confirm).not.toHaveBeenCalled();
    expect(center.calls).toEqual([]);
  });

  it("share_status validates its job id", async () => {
    const tools = fixedTools(host(fakeCenter(), 0).host);
    await expect(tools.share_status({}, signal)).rejects.toThrow(/missing job_id/);
    await expect(tools.share_status({ job_id: "NOPE" }, signal)).rejects.toThrow(/unknown job_id/);
  });
});

describe("share tools in the WebMCP catalog", () => {
  it("come from the Mac catalog with outputSchema, a closed input and the house hints", () => {
    const mac = (catalog.tools as unknown as Array<{ name: string; outputSchema?: { type: string }; annotations: Record<string, unknown> }>).find(
      (t) => t.name === "share_project",
    )!;
    expect(mac.outputSchema?.type).toBe("object");
    expect(mac.annotations).toMatchObject({ readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true });
    const web = webCatalog().find((t) => t.name === "share_project")!;
    expect(web.inputSchema.required ?? []).not.toContain("project_id");
    expect(web.inputSchema.additionalProperties).toBe(false);
    expect(web.description).toMatch(/approval/);
  });

  it("registers share_project as consequential and share_status as read-only", () => {
    const registered: ModelContextToolDescriptor[] = [];
    const tools = fixedTools(host(fakeCenter(), 0).host);
    registerEditorTools(tools, { registerTool: (t) => void registered.push(t) });
    const share = registered.find((t) => t.name === "share_project")!;
    const status = registered.find((t) => t.name === "share_status")!;
    expect(share.annotations).toEqual({ readOnlyHint: false, consequentialHint: true });
    expect(status.annotations).toEqual({ readOnlyHint: true, consequentialHint: false });
  });
});
