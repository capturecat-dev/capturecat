/**
 * "Continue on Mac" — hand the project open in the web editor to the Mac app.
 *
 * Every web project is already a cloud project in the Mac's own format
 * (recording.mov, camera, voice-overs, images, project.json), so the
 * handoff is: save what is on screen, then open
 * `capturecat://open-project?id=<id>&from=web`. The Mac app
 * (Services/DeepLinkHandler.swift) opens the project — downloading it into a
 * new project folder when this Mac never had it (CloudProjectSync.clone), or
 * pulling the web's newer edits into the copy it has.
 *
 * A browser cannot tell whether a custom scheme opened anything. When the
 * app takes the link the page loses focus (the OS hands over, or the browser
 * asks "Open CaptureCat?"); if it is still focused after `waitMs`, the user
 * is offered the download instead.
 */
import { SITE_URL } from "@/lib/api-url";

/** The deep link the Mac app's DeepLinkHandler understands. */
export function continueOnMacUrl(projectId: string): string {
  return `capturecat://open-project?id=${encodeURIComponent(projectId)}&from=web`;
}

export const MAC_DOWNLOAD_URL = `${SITE_URL}/download`;

export interface HandoffEnv {
  /** Navigate to the custom scheme (a top-level navigation; it never leaves the page). */
  open: (url: string) => void;
  /** Resolves true if the page lost focus or was hidden within `waitMs`. */
  watchFocusLoss: (waitMs: number) => Promise<boolean>;
}

export function browserHandoffEnv(win: Window = window, doc: Document = document): HandoffEnv {
  return {
    open: (url) => {
      win.location.href = url;
    },
    watchFocusLoss: (waitMs) =>
      new Promise((resolve) => {
        let done = false;
        const finish = (lost: boolean) => {
          if (done) return;
          done = true;
          win.removeEventListener("blur", onLoss);
          win.removeEventListener("pagehide", onLoss);
          doc.removeEventListener("visibilitychange", onVisibility);
          clearTimeout(timer);
          resolve(lost);
        };
        const onLoss = () => finish(true);
        const onVisibility = () => doc.visibilityState === "hidden" && finish(true);
        win.addEventListener("blur", onLoss);
        win.addEventListener("pagehide", onLoss);
        doc.addEventListener("visibilitychange", onVisibility);
        const timer = setTimeout(() => finish(false), waitMs);
      }),
  };
}

export type HandoffResult = "opened" | "no-app" | "save-failed";

/**
 * Save, then open the Mac app. `flush` must resolve once the server has the
 * document (EditorStore.flush); `saved()` reports whether anything is still
 * unsaved afterwards (a conflict or offline save) — the Mac would then open
 * an older version, so the handoff stops and says so.
 */
export async function continueOnMac(
  projectId: string,
  deps: { flush: () => Promise<void>; saved: () => boolean; env?: HandoffEnv; waitMs?: number },
): Promise<HandoffResult> {
  await deps.flush();
  if (!deps.saved()) return "save-failed";
  const env = deps.env ?? browserHandoffEnv();
  const lost = env.watchFocusLoss(deps.waitMs ?? 1600);
  env.open(continueOnMacUrl(projectId));
  return (await lost) ? "opened" : "no-app";
}
