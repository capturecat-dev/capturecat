import { describe, expect, it } from "vitest";

import { newProject, type Project } from "../core/model";
import { CameraMaskJob, MEMBER_NOTICE, projectUsesLook } from "./cameraMask";
import type { SegmentOptions, SegmentResult, Segmenter } from "../segment/protocol";

function project(look: boolean): Project {
  const p = newProject({ id: "11111111-2222-4333-8444-555555555556", duration: 10 });
  p.cameraVideoURL = "file:///x/camera.mov";
  p.cameraLayoutRegions = [{ id: "A", startTime: 1, endTime: 5, mode: "bubble", ...(look ? { look: "cutout" as const } : {}) }];
  return p;
}

function fakeSegmenter(result: SegmentResult, calls: SegmentOptions[]): Segmenter {
  return {
    segment: async (_url, opts = {}) => {
      calls.push(opts);
      opts.onProgress?.({ type: "progress", jobId: 1, stage: "segment", fraction: 0.5 });
      return result;
    },
    dispose: () => undefined,
  };
}

function media(canAddFiles: boolean, added: string[]) {
  return {
    canAddFiles,
    mediaUrl: (ref: string | null | undefined) => (ref ? `blob:${ref}` : undefined),
    addFile: async (f: { ref: string }) => void added.push(f.ref),
  };
}

describe("CameraMaskJob", () => {
  it("only runs for a project that uses a look", async () => {
    expect(projectUsesLook(project(false))).toBe(false);
    const calls: SegmentOptions[] = [];
    const job = new CameraMaskJob({ getState: () => ({ project: project(false) }) }, () => media(true, []), () => null, () => fakeSegmenter({ kind: "fresh" }, calls));
    expect(await job.ensure()).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it("owner: segments, hands the mask to the engine, uploads camera-mask.ccmask", async () => {
    const calls: SegmentOptions[] = [];
    const added: string[] = [];
    const engine: Uint8Array[] = [];
    const bytes = new Uint8Array([1, 2, 3]);
    const job = new CameraMaskJob(
      { getState: () => ({ project: project(true) }) },
      () => media(true, added),
      () => ({ setCameraMask: (b) => void engine.push(b) }),
      () => fakeSegmenter({ kind: "done", bytes, stats: { device: "cpu", frames: 1, width: 1, height: 1, bytes: 3, loadMs: 0, segmentMs: 0 } }, calls),
    );
    expect(await job.ensure()).toBe(true);
    expect(calls[0]).toMatchObject({ maskUrl: "blob:camera-mask.ccmask", checkOnly: false });
    expect(engine).toEqual([bytes]);
    expect(added).toEqual(["camera-mask.ccmask"]);
    expect(job.getStatus()).toMatchObject({ busy: false, error: null });
    // Settled for this camera: a second look does not re-run.
    expect(await job.ensure()).toBe(true);
    expect(calls).toHaveLength(1);
  });

  it("member: only checks, and says why there is no cutout", async () => {
    const calls: SegmentOptions[] = [];
    const job = new CameraMaskJob({ getState: () => ({ project: project(true) }) }, () => media(false, []), () => null, () => fakeSegmenter({ kind: "stale" }, calls));
    expect(await job.ensure()).toBe(false);
    expect(calls[0]!.checkOnly).toBe(true);
    expect(job.getStatus().notice).toBe(MEMBER_NOTICE);
  });
});
