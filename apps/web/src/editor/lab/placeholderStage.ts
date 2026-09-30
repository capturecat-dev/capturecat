/**
 * DEV-ONLY stand-in for the engine on the lab stage: a plain 2D canvas that
 * paints the fixture's background + a grey card so the shell can be compared
 * against the Mac capture. It is NOT a renderer — no parity math lives here;
 * the real stage is `editor/engine` mounting through the same StageMount.
 */
import type { ProjectSettings } from "../core/model";
import type { StageMount, StageViewport } from "../ui/shell/types";

const css = (c: { red: number; green: number; blue: number; opacity: number }) =>
  `rgba(${Math.round(c.red * 255)},${Math.round(c.green * 255)},${Math.round(c.blue * 255)},${c.opacity})`;

export function placeholderStage(
  get: () => ProjectSettings,
  subscribe: (fn: () => void) => () => void,
): StageMount {
  let canvas: HTMLCanvasElement | null = null;
  let vp: StageViewport | null = null;

  const paint = () => {
    if (!canvas || !vp) return;
    const s = get();
    const w = Math.max(1, vp.cssWidth);
    const h = Math.max(1, vp.cssHeight);
    canvas.width = Math.round(w * vp.dpr);
    canvas.height = Math.round(h * vp.dpr);
    const ctx = canvas.getContext("2d")!;
    ctx.setTransform(vp.dpr, 0, 0, vp.dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    // Background fill.
    if (s.backgroundType === "Gradient" || s.backgroundType === "Mesh") {
      const angle = ((s.gradientAngle ?? 135) * Math.PI) / 180;
      // CSS convention: 0° points up, clockwise.
      const dx = Math.sin(angle);
      const dy = -Math.cos(angle);
      const half = (Math.abs(w * dx) + Math.abs(h * dy)) / 2;
      const g = ctx.createLinearGradient(w / 2 - dx * half, h / 2 - dy * half, w / 2 + dx * half, h / 2 + dy * half);
      g.addColorStop(0, css(s.gradientStartColor));
      g.addColorStop(1, css(s.gradientEndColor));
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, w, h);
    } else if (s.backgroundType === "Solid Color") {
      ctx.fillStyle = css(s.solidColor);
      ctx.fillRect(0, 0, w, h);
    } else if (s.backgroundType !== "Transparent") {
      const g = ctx.createLinearGradient(0, 0, w, h);
      g.addColorStop(0, "#1d2b64");
      g.addColorStop(1, "#f8cdda");
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, w, h);
    }

    // The recording card (1280×800 grey frame), padded + placed.
    const scale = h / 370; // the probe's reference preview height
    const pad = s.backgroundPadding * scale;
    const availW = Math.max(1, w - pad * 2);
    const availH = Math.max(1, h - pad * 2);
    const aspect = 1280 / 800;
    let cw = availW;
    let ch = cw / aspect;
    if (ch > availH) {
      ch = availH;
      cw = ch * aspect;
    }
    const fx = s.videoCustomX ?? placementFraction(s.videoPlacement)[0];
    const fy = s.videoCustomY ?? placementFraction(s.videoPlacement)[1];
    const x = pad + (availW - cw) * fx;
    const y = pad + (availH - ch) * fy;
    const r = s.frameShape === "Rectangle" ? 0 : Math.max(0, s.windowCornerRadius * 1.5) * scale;
    ctx.save();
    ctx.shadowColor = `rgba(0,0,0,${s.shadowOpacity})`;
    ctx.shadowBlur = s.shadowRadius * scale * vp.dpr;
    ctx.shadowOffsetY = 0;
    ctx.beginPath();
    ctx.roundRect(x, y, cw, ch, r);
    ctx.fillStyle = "rgb(80,80,80)";
    ctx.fill();
    ctx.restore();
  };

  return {
    mount(host, viewport) {
      vp = viewport;
      canvas = document.createElement("canvas");
      canvas.dataset.labPlaceholder = "true";
      host.appendChild(canvas);
      paint();
      const unsub = subscribe(paint);
      return () => {
        unsub();
        canvas?.remove();
        canvas = null;
      };
    },
    onViewport(viewport) {
      vp = viewport;
      paint();
    },
  };
}

function placementFraction(p: ProjectSettings["videoPlacement"]): [number, number] {
  const map: Record<string, [number, number]> = {
    "Top Left": [0, 0],
    Top: [0.5, 0],
    "Top Right": [1, 0],
    Left: [0, 0.5],
    Center: [0.5, 0.5],
    Right: [1, 0.5],
    "Bottom Left": [0, 1],
    Bottom: [0.5, 1],
    "Bottom Right": [1, 1],
  };
  return map[p] ?? [0.5, 0.5];
}
