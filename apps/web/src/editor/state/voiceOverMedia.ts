/**
 * Where a recorded voice-over file goes — through the project's media
 * (state/projectMedia.ts), exactly like an image the user picks:
 *
 *   cloud   ProjectMedia stages the complete manifest + the take, uploads,
 *           finalizes; the page's project.json save waits for it
 *           (`media.settled()`), so the Mac never pulls a clip whose file
 *           the cloud does not have
 *   local   (dev server, the Mac's own folder, read-only) — the file lives in
 *           the tab like every other local edit
 *
 * Either way the file plays at once: ProjectMedia serves it from its object
 * URL and pushes it to the engine (playback + export) as soon as it is added.
 */
import type { RecordedVoiceOver } from "../record/voiceOverRecorder";
import { CloudApiError } from "./cloud";
import type { ProjectMedia } from "./projectMedia";
import type { VoiceOverMedia } from "./voiceOver";

/** Transient = worth retrying (offline, 5xx, rate limit). */
function transient(error: unknown): boolean {
  if (error instanceof CloudApiError) return error.status >= 500 || error.status === 429;
  return error instanceof TypeError || (error instanceof Error && /Upload failed \(HTTP (0|5\d\d)\)/.test(error.message));
}

const RETRY_DELAYS_MS = [2_000, 5_000, 10_000];

export function createVoiceOverMedia(opts: {
  media: ProjectMedia | undefined;
  /** Test seam. */
  sleep?: (ms: number) => Promise<void>;
}): VoiceOverMedia {
  const { media } = opts;
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  // register() hands over the take's object URL; persist() (called next, with
  // the take) adds the file under it — before the clip reaches the store.
  const urls = new Map<string, string>();

  return {
    register(fileName, url) {
      urls.set(fileName, url);
    },

    blocker() {
      return media && !media.canAddFiles ? "Only the project's owner can add a voice over." : null;
    },

    persist(take: RecordedVoiceOver) {
      if (!media) return Promise.resolve();
      const add = () =>
        media.addFile({
          ref: take.fileName,
          path: take.fileName,
          blob: take.file,
          contentType: take.contentType,
          url: urls.get(take.fileName),
        });
      // The first add is synchronous up to the upload: the file resolves now.
      const first = add();
      return (async () => {
        let attempt = 0;
        let pending = first;
        for (;;) {
          try {
            await pending;
            return;
          } catch (error) {
            if (attempt < RETRY_DELAYS_MS.length && transient(error)) {
              await sleep(RETRY_DELAYS_MS[attempt++]);
              pending = add();
              continue;
            }
            const reason = error instanceof Error && error.message ? ` ${error.message}` : "";
            throw new Error(`The voice over couldn't be uploaded to the cloud.${reason}`);
          }
        }
      })();
    },
  };
}
