import { describe, expect, it, vi } from "vitest";

import type { RecordedVoiceOver } from "../record/voiceOverRecorder";
import { CloudApiError, type LoadedCloudProject, type ManifestFile } from "./cloud";
import { MediaUrlRefresher } from "./mediaRefresh";
import { ProjectMedia } from "./projectMedia";
import { createVoiceOverMedia } from "./voiceOverMedia";

const ID = "11111111-2222-3333-4444-555555555555";

function cloudProject(access: "owner" | "member" = "owner"): LoadedCloudProject {
  return {
    projectId: ID,
    name: "Demo",
    revision: 2,
    documentSha256: null,
    access,
    isOwner: access === "owner",
    orgId: null,
    updatedAt: "",
    document: "{}",
    media: {
      "recording.mov": { path: "recording.mov", sha256: "a".repeat(64), bytes: 3, contentType: "video/quicktime", source: null, url: "https://r2.test/recording.mov" },
    },
    sources: {},
    urlsExpireAt: Date.now() + 900_000,
  };
}

const take = (): RecordedVoiceOver =>
  ({
    fileName: "voiceover-TAKE.m4a",
    file: new File([new Uint8Array([1, 2, 3])], "voiceover-TAKE.m4a", { type: "audio/mp4" }),
    contentType: "audio/mp4",
    duration: 2.5,
  }) as unknown as RecordedVoiceOver;

function cloudMedia(commitFiles: ConstructorParameters<typeof ProjectMedia>[0]["commitFiles"], access: "owner" | "member" = "owner") {
  const loaded = cloudProject(access);
  return new ProjectMedia({
    projectId: ID,
    origin: "cloud",
    cloud: loaded,
    refresher: new MediaUrlRefresher(ID, loaded, { fetchUrls: async () => loaded }),
    commitFiles,
    createObjectURL: () => "blob:unused",
  });
}

const committed = { projectId: ID, revision: 2, documentSha256: null, missing: [], presentCount: 2, expiresIn: 900 };

describe("createVoiceOverMedia (on ProjectMedia)", () => {
  it("the take resolves to its own object URL the moment persist() starts", () => {
    const media = new ProjectMedia({ projectId: ID, origin: "local", localUrl: () => undefined, createObjectURL: () => "blob:unused" });
    const vo = createVoiceOverMedia({ media });
    vo.register("voiceover-TAKE.m4a", "blob:take");
    void vo.persist(take());
    expect(media.mediaUrl("voiceover-TAKE.m4a")).toBe("blob:take");
  });

  it("cloud: stages the full manifest + the hashed take, retrying transient failures", async () => {
    const manifests: ManifestFile[][] = [];
    let calls = 0;
    const commitFiles = vi.fn(async (_id: string, opts: { manifest: ManifestFile[] }) => {
      manifests.push(opts.manifest);
      if (++calls === 1) throw new CloudApiError(503, { error: "Service unavailable" });
      return committed;
    });
    const media = cloudMedia(commitFiles as never);
    const vo = createVoiceOverMedia({ media, sleep: async () => undefined });
    vo.register("voiceover-TAKE.m4a", "blob:take");
    await vo.persist(take());
    expect(commitFiles).toHaveBeenCalledTimes(2);
    const last = manifests.at(-1)!;
    expect(last.map((f) => f.path).sort()).toEqual(["recording.mov", "voiceover-TAKE.m4a"]);
    const added = last.find((f) => f.path === "voiceover-TAKE.m4a")!;
    // sha256 of bytes 01 02 03
    expect(added.sha256).toBe("039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81");
    expect(added).toMatchObject({ bytes: 3, contentType: "audio/mp4" });
    await media.settled();
  });

  it("cloud: a permanent failure rejects with a user-facing message", async () => {
    const media = cloudMedia((async () => {
      throw new CloudApiError(413, { error: "Storage limit reached" });
    }) as never);
    const vo = createVoiceOverMedia({ media, sleep: async () => undefined });
    vo.register("voiceover-TAKE.m4a", "blob:take");
    await expect(vo.persist(take())).rejects.toThrow(/^The voice over couldn't be uploaded to the cloud\. .*Storage limit reached/);
  });

  it("a team member cannot add a voice over (owner-only media)", () => {
    const vo = createVoiceOverMedia({ media: cloudMedia(vi.fn() as never, "member") });
    expect(vo.blocker?.()).toBe("Only the project's owner can add a voice over.");
  });
});
