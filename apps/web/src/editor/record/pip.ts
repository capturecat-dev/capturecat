/**
 * Floating recording controls — the web's stand-in for the Mac panel that
 * floats above every app during a take. Document Picture-in-Picture (Chrome,
 * Edge) opens an always-on-top mini window; the page renders the control bar
 * into it through a React portal, so the SAME components drive both.
 *
 * The window is a real window on screen: a DISPLAY (whole-screen) share
 * would record it, which the Mac avoids by excluding its own UI from
 * capture. So the page only floats the controls for window/tab shares.
 */

interface DocumentPictureInPicture {
  requestWindow(options?: { width?: number; height?: number; disallowReturnToOpener?: boolean }): Promise<Window>;
  window: Window | null;
}

function pipApi(): DocumentPictureInPicture | null {
  return ((globalThis as unknown as { documentPictureInPicture?: DocumentPictureInPicture }).documentPictureInPicture ?? null);
}

export function pipSupported(): boolean {
  return pipApi() !== null;
}

/**
 * Open the floating window (needs a user gesture) with the page's styles
 * copied in. Resolves with the mount element, or null where unsupported or
 * refused. `onClosed` fires when the person closes it.
 */
export async function openControlsWindow(
  size: { width: number; height: number },
  onClosed: () => void,
): Promise<{ win: Window; mount: HTMLElement } | null> {
  const api = pipApi();
  if (!api) return null;
  let win: Window;
  try {
    win = await api.requestWindow({ width: size.width, height: size.height, disallowReturnToOpener: false });
  } catch {
    return null;
  }
  const doc = win.document;
  doc.title = "CaptureCat — Recording";
  // Styles: <link> in production, <style> injected by Vite in dev — copy both.
  for (const node of Array.from(document.head.querySelectorAll('link[rel="stylesheet"], style'))) {
    doc.head.appendChild(node.cloneNode(true));
  }
  // Same theme scope as the page (the dashboard forces `dark` on <html>).
  doc.documentElement.className = document.documentElement.className;
  doc.documentElement.style.colorScheme = getComputedStyle(document.documentElement).colorScheme;
  doc.body.style.margin = "0";
  doc.body.style.overflow = "hidden";
  const mount = doc.createElement("div");
  mount.style.cssText = "position:fixed;inset:0;display:flex";
  doc.body.appendChild(mount);
  win.addEventListener("pagehide", () => onClosed(), { once: true });
  return { win, mount };
}

export function closeControlsWindow(win: Window | null): void {
  try {
    win?.close();
  } catch {
    // already gone
  }
}
