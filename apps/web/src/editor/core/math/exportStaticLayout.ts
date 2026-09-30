/**
 * VideoExporter.export's `staticLayout` — device recordings reserve bezel
 * room around the video (iterated 3×, kept centred) — plus the card's
 * outer/inner corner radii. Y-UP output pixels like exportLayout.ts.
 * Locked by the `exportStaticLayout` vectors (real DeviceFrameLayout).
 */
import type { ProjectSettings } from "../model/types";
import { midX, midY, rectHeight, rectWidth } from "./geometry";
import { smax, smin } from "./swift";
import { bezelWidth, screenCornerRadius } from "./deviceFrameLayout";
import type { FrameLayout } from "./exportLayout";

export function staticLayout(
  layout: FrameLayout,
  deviceFrameActive: boolean,
  settings: Pick<ProjectSettings, "frameShape" | "cornerRadius" | "windowCornerRadius">,
  scale: number,
): { layout: FrameLayout; outerCornerRadius: number; innerCornerRadius: number } {
  let out = layout;
  if (deviceFrameActive) {
    let s = 1;
    for (let i = 0; i < 3; i++) {
      const bezel = bezelWidth(rectWidth(layout.videoRect) * s);
      s = smin(
        (rectWidth(layout.contentRect) - 2 * bezel) / rectWidth(layout.videoRect),
        (rectHeight(layout.contentRect) - 2 * bezel) / rectHeight(layout.videoRect),
      );
    }
    s = smax(0.01, smin(1, s));
    const newWidth = rectWidth(layout.videoRect) * s;
    const newHeight = rectHeight(layout.videoRect) * s;
    out = {
      contentRect: layout.contentRect,
      videoRect: {
        x: midX(layout.videoRect) - newWidth / 2,
        y: midY(layout.videoRect) - newHeight / 2,
        width: newWidth,
        height: newHeight,
      },
      videoScale: layout.videoScale * s,
    };
  }
  const outerCornerRadius =
    deviceFrameActive || settings.frameShape === "Rectangle" ? 0 : smax(0, settings.cornerRadius * scale);
  const innerCornerRadius = deviceFrameActive
    ? screenCornerRadius({ width: out.videoRect.width, height: out.videoRect.height })
    : smax(0, settings.windowCornerRadius * scale);
  return { layout: out, outerCornerRadius, innerCornerRadius };
}

