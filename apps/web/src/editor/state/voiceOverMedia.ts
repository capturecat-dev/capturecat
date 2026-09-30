/**
 * Where a recorded voice-over file goes — persisted "the way the project's
 * other media is":
 *
 *   cloud   uploaded into the cloud project's manifest (state/cloudMedia.ts);
 *           project saves wait for it (UploadGate), then the store's autosave
 *           carries the new clip to project.json so the Mac pulls it
 *   local   (dev server, the Mac's own folder, read-only) — the file lives in
 *           the tab like every other local edit
 *
 * Either way the file plays at once: its blob: URL is registered with the
 * engine (playback + export) and with the page's media resolver.
 */
import type { RecordedVoiceOver } from "../record/voiceOverRecorder";
import { CloudApiError } from "./cloud";
import { addCloudProjectFile } from "./cloudMedia";
import type { EditorController } from "./controller";
import type { LoadedEditorProject } from "./projectSource";
import type { EditorStore } from "./store";
import type { UploadGate, VoiceOverMedia } from "./voiceOver";

const overrides = new WeakMap<LoadedEditorProject, Map<string, string>>();

/** `loaded.mediaUrl(ref)` resolves `ref` to `url` from now on (a file made in this tab). */
export function registerTabMedia(loaded: LoadedEditorProject, ref: string, url: string): void {
  let map = overrides.get(loaded);
  if (!map) {
    const extra = new Map<string, string>();
    const base = loaded.mediaUrl.bind(loaded);
    loaded.mediaUrl = (r) => (r ? extra.get(r) : undefined) ?? base(r);
    overrides.set(loaded, extra);
    map = extra;
  }
  map.set(ref, url);
}

/** Transient = worth retrying (offline, 5xx, rate limit). */
function transient(error: unknown): boolean {
  if (error instanceof CloudApiError) return error.status >= 500 || error.status === 429;
  return error instanceof TypeError || (error instanceof Error && /Upload failed \(HTTP (0|5\d\d)\)/.test(error.message));
}

const RETRY_DELAYS_MS = [2_000, 5_000, 10_000];

export function createVoiceOverMedia(opts: {
  loaded: LoadedEditorProject;
  store: EditorStore;
  controller: EditorController;
  uploads: UploadGate;
  /** Test seam: the cloud upload. */
  upload?: typeof addCloudProjectFile;
  sleep?: (ms: number) => Promise<void>;
}): VoiceOverMedia {
  const { loaded, store, controller, uploads } = opts;
  const upload = opts.upload ?? addCloudProjectFile;
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));

  return {
    register(fileName, url) {
      controller.client?.addMediaFiles({ [fileName]: url });
      registerTabMedia(loaded, fileName, url);
    },

    blocker() {
      if (loaded.origin === "cloud" && loaded.cloud && loaded.cloud.access !== "owner") {
        return "Only the project's owner can add a voice over.";
      }
      return null;
    },

    persist(take: RecordedVoiceOver) {
      const cloud = loaded.cloud;
      if (loaded.origin !== "cloud" || !cloud) return Promise.resolve();
      const work = (async () => {
        for (let attempt = 0; ; attempt++) {
          try {
            const fresh = await upload(loaded.id, {
              name: store.getState().project?.name ?? cloud.name,
              path: take.fileName,
              file: take.file,
              contentType: take.contentType,
            });
            cloud.media = fresh.media;
            cloud.sources = fresh.sources;
            cloud.urlsExpireAt = fresh.urlsExpireAt;
            return;
          } catch (error) {
            if (attempt < RETRY_DELAYS_MS.length && transient(error)) {
              await sleep(RETRY_DELAYS_MS[attempt]);
              continue;
            }
            const reason = error instanceof Error && error.message ? ` ${error.message}` : "";
            throw new Error(`The voice over couldn't be uploaded to the cloud.${reason}`);
          }
        }
      })();
      return uploads.track(work);
    },
  };
}
