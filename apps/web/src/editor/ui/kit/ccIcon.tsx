/**
 * CaptureCat's own icon kit on the web — the twin of the Mac's CCIcon
 * (Views/Shared/DesignKit/CCIcon.swift + CCIconSet.swift, the 2026-10-27
 * restyle that replaced SF Symbols in the app's CHROME).
 *
 * Data: `ccIcons.generated.ts` (scripts/gen-cc-icons.mjs ← apps/macos/IconKit/icons.json, shared with the Mac).
 * Icons are line drawings on a 24×24 grid, stroke 1.75 with round caps/joins,
 * thickened for heavier weights exactly like CCIcon.strokeScale.
 *
 * Rendering: inline SVG in `currentColor`. The glyph is drawn into an ALPHA
 * mask and ONE currentColor rect is painted through it, so a translucent ink
 * (muted text is white .58) composites once — painting the strokes directly
 * would double the alpha wherever a fill and its stroke (or two strokes)
 * overlap. Same look as the Mac's template images.
 *
 * CONTENT never uses this: nothing drawn INTO a recording or export (engine/,
 * core/) may read the kit — the parity gate compares those against the Mac's
 * SF-drawn exporter.
 *
 * This module is deliberately light (no lucide) so the dashboard can use the
 * kit without pulling the editor's SF fallback table.
 */
import { useId, useMemo, type CSSProperties, type SVGProps } from "react";

import { CC_ICONS, CC_ICON_ALIASES, CC_ICON_STROKE } from "./ccIcons.generated";

export type CCIconWeight = "light" | "regular" | "medium" | "semibold" | "bold";

/** CCIcon.strokeScale — the stroke thickens with the requested weight. */
const STROKE_SCALE: Record<CCIconWeight, number> = {
  light: 0.9,
  regular: 1,
  medium: 1.08,
  semibold: 1.16,
  bold: 1.25,
};

/** The kit icon a name resolves to (a kit name, or an SF alias), if any. */
export function ccKitName(name: string): string | null {
  if (CC_ICONS[name] !== undefined) return name;
  return CC_ICON_ALIASES[name] ?? null;
}

/** The kit glyph's body in solid black (for masks / rasterising), or null. */
export function ccKitBody(name: string, weight: CCIconWeight = "regular"): string | null {
  const kit = ccKitName(name);
  if (!kit) return null;
  const markup = CC_ICONS[kit];
  const sw = +(CC_ICON_STROKE * STROKE_SCALE[weight]).toFixed(3);
  return (
    `<g fill="none" stroke="#000" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round">` +
    markup.replace(/currentColor/g, "#000") +
    `</g>`
  );
}

/**
 * Inline-SVG markup that paints `body` (black = opaque) in currentColor
 * through an alpha mask. `uid` must be unique in the document.
 */
export function maskedGlyphMarkup(body: string, uid: string): string {
  return (
    `<defs><mask id="${uid}" maskUnits="userSpaceOnUse" x="-2" y="-2" width="28" height="28" style="mask-type:alpha">` +
    body +
    `</mask></defs><rect x="-2" y="-2" width="28" height="28" fill="currentColor" mask="url(#${uid})"/>`
  );
}

/** A unique, selector-safe id per mounted glyph. */
export function useGlyphId(): string {
  return `ccg${useId().replace(/[^a-zA-Z0-9]/g, "")}`;
}

/**
 * <CCIcon name="trash" /> — a kit icon (kit name or SF alias) at `size` CSS px.
 * Renders an empty box for a name the kit does not draw (callers that need a
 * fallback check `ccKitName` first; the editor's SFIcon falls back to lucide).
 */
export function CCIcon({
  name,
  size = 16,
  weight = "regular",
  className,
  style,
  title,
  ...rest
}: Omit<SVGProps<SVGSVGElement>, "name" | "children" | "dangerouslySetInnerHTML" | "ref"> & {
  name: string;
  /** Box side in CSS px. */
  size?: number;
  weight?: CCIconWeight;
  className?: string;
  style?: CSSProperties;
  /** Accessible name; omit for decorative icons (aria-hidden). */
  title?: string;
}) {
  const uid = useGlyphId();
  const body = ccKitBody(name, weight);
  // ONE object per glyph: React rewrites innerHTML whenever this prop's
  // identity changes, so a fresh object per render would replace the glyph's
  // nodes on every re-render — under a pointer that breaks :active and loses
  // the click (the recording bar re-renders at frame rate while a mic meter
  // is live).
  const html = useMemo(() => (body ? { __html: maskedGlyphMarkup(body, uid) } : undefined), [body, uid]);
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      role={title ? "img" : undefined}
      aria-label={title}
      aria-hidden={title ? undefined : true}
      focusable="false"
      {...rest}
      style={{ display: "inline-block", flex: "none", overflow: "visible", ...style }}
      dangerouslySetInnerHTML={html}
    />
  );
}
