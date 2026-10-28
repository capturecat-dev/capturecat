/**
 * The camera in the browser's own picture-in-picture window, for browsers
 * without Document Picture-in-Picture (Safari) or with the floating controls
 * turned off. This is the web twin of the Mac's recording-time camera float
 * (Views/AppKitSurfaces/CameraFloatPreview.swift), which stays on screen
 * while the capture leaves it out.
 *
 * A video PiP window is a window of its own: a WINDOW or TAB capture never
 * contains it, so the camera stays on screen for those takes and still never
 * reaches the recording — camera.mov is recorded on its own and the editor
 * composites it. A DISPLAY capture would contain it, so for a display the
 * camera keeps stepping aside (cameraBubble.ts bubblePolicy).
 *
 * `requestPictureInPicture` needs the Record click's activation and a video
 * that already has frames, so the camera plays in one persistent, invisible
 * element (`primeCameraPip`) and the press enters it synchronously.
 */

let video: HTMLVideoElement | null = null;
const listeners = new Set<(open: boolean) => void>();

type PipDocument = Document & { pictureInPictureEnabled?: boolean; pictureInPictureElement?: Element | null; exitPictureInPicture?: () => Promise<void> };
type PipVideo = HTMLVideoElement & { requestPictureInPicture?: () => Promise<unknown> };

/** Whether this browser can float a video in its own picture-in-picture window. */
export function cameraPipSupported(): boolean {
  if (typeof document === "undefined" || typeof HTMLVideoElement === "undefined") return false;
  return (
    (document as PipDocument).pictureInPictureEnabled === true &&
    typeof (HTMLVideoElement.prototype as PipVideo).requestPictureInPicture === "function"
  );
}

function notify(open: boolean): void {
  for (const fn of listeners) fn(open);
}

function element(): HTMLVideoElement {
  if (video) return video;
  const v = document.createElement("video");
  v.muted = true;
  v.playsInline = true;
  v.autoplay = true;
  v.setAttribute("aria-hidden", "true");
  v.dataset.recUi = "camera-pip";
  // Laid out (a 0×0 or display:none video gets no frames in some engines),
  // never seen and never in the way.
  Object.assign(v.style, {
    position: "fixed",
    left: "0",
    bottom: "0",
    width: "2px",
    height: "2px",
    opacity: "0",
    pointerEvents: "none",
  } satisfies Partial<CSSStyleDeclaration>);
  v.addEventListener("enterpictureinpicture", () => notify(true));
  v.addEventListener("leavepictureinpicture", () => notify(false));
  document.body.appendChild(v);
  video = v;
  return v;
}

/** Keep the camera playing in the hidden element, ready for the press; null releases it. */
export function primeCameraPip(stream: MediaStream | null): void {
  if (!cameraPipSupported()) return;
  if (!stream) {
    if (video) {
      exitCameraPip();
      video.srcObject = null;
    }
    return;
  }
  const v = element();
  if (v.srcObject !== stream) v.srcObject = stream;
  void v.play().catch(() => undefined);
}

/**
 * Float the camera. Call it INSIDE the Record click, before any await: the
 * browser only opens the window for a user gesture. Resolves to whether it
 * opened.
 */
export function enterCameraPip(): Promise<boolean> {
  const v = video as PipVideo | null;
  if (!v || !v.srcObject || !v.requestPictureInPicture || v.readyState < 1) return Promise.resolve(false);
  return v.requestPictureInPicture().then(
    () => true,
    () => false,
  );
}

/** Close the floating camera if it is ours and open. */
export function exitCameraPip(): void {
  const d = document as PipDocument;
  if (video && d.pictureInPictureElement === video) void d.exitPictureInPicture?.().catch(() => undefined);
}

/** Open / closed (closed includes the viewer closing the window themselves). */
export function onCameraPipChange(fn: (open: boolean) => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
