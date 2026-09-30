/**
 * The slice tool's skeuomorphic scissors — a port of
 * `Views/Editor/ScissorsGlyph.swift`: polished-steel blades pointing UP,
 * silver finger loops below, both halves rigid blade+loop pieces rotated
 * about the pivot so one `open` value drives a believable close.
 *
 * The Swift glyph is authored in y-up handler space and lands blades-up on
 * the flipped timeline canvas; here the same geometry is drawn under a
 * vertical flip into the (y-down) canvas, so the numbers match 1:1.
 *
 * `snipState` / `stripGap` are the shared timing the Mac's snip animation
 * (TimelineCanvasView.drawSnipAnimation) and its harness assert on.
 */

/** `ScissorsGlyph.snipDuration`. */
export const SNIP_DURATION = 0.55;

/** `ScissorsGlyph.image(height:open:)` width for a glyph `height` tall. */
export function scissorsWidth(height: number): number {
  return height * 0.95;
}

/**
 * `ScissorsGlyph.snipState(at:)` — (open, travel, alpha) `t` seconds into
 * the snip: a crisp close over the first third, a small elastic re-part,
 * then a fade. `travel` is the eased 0→1 ride UP through the lane.
 */
export function snipState(t: number): { open: number; travel: number; alpha: number } {
  const p = Math.max(0, Math.min(1, t / SNIP_DURATION));
  const closeP = Math.min(1, p / 0.33);
  const eased = closeP * closeP * (3 - 2 * closeP);
  let open = 1 - eased;
  if (p > 0.33) {
    const w = (p - 0.33) / 0.67;
    open = 0.12 * Math.sin(w * Math.PI * 2) * Math.exp(-3 * w);
  }
  const travel = p * p * (3 - 2 * p);
  const alpha = p < 0.6 ? 1 : 1 - (p - 0.6) / 0.4;
  return { open: Math.max(0, open), travel, alpha };
}

/** `ScissorsGlyph.stripGap(at:maxGap:)` — how far each clip half leans away from the cut. */
export function stripGap(t: number, maxGap: number): number {
  const p = Math.max(0, Math.min(1, t / SNIP_DURATION));
  return maxGap * Math.sin(p * Math.PI);
}

const grey = (w: number, a = 1) => {
  const v = Math.round(w * 255);
  return `rgba(${v},${v},${v},${a})`;
};

/**
 * Draws the scissors with their top-left at (x, y), `height` tall
 * (`scissorsWidth(height)` wide), blades `open` (1 apart … 0 closed), at
 * `alpha` (`NSImage.draw(… fraction:)`).
 */
export function drawScissors(ctx: CanvasRenderingContext2D, x: number, y: number, height: number, open: number, alpha = 1): void {
  if (alpha <= 0) return;
  const width = scissorsWidth(height);
  const spread = 0.08 + 0.34 * Math.max(0, Math.min(1, open));
  const pivot = { x: width / 2, y: height * 0.38 };
  const bladeLen = height * 0.6;
  const bladeBulge = height * 0.16;
  const loopRadius = height * 0.105;
  const loopStroke = Math.max(1.4, height * 0.055);
  const edge = grey(0.35, 0.9);

  ctx.save();
  ctx.globalAlpha *= alpha;
  // y-up handler space → canvas (blades up on screen).
  ctx.translate(x, y + height);
  ctx.scale(1, -1);

  for (const side of [-1, 1]) {
    ctx.save();
    ctx.translate(pivot.x, pivot.y);
    // Each side splays OUTWARD (side +1's tip to the right).
    ctx.rotate(-side * spread);

    // Blade: slender lens from pivot to tip, bulge on the outside.
    const blade = new Path2D();
    blade.moveTo(0, 0);
    blade.quadraticCurveTo(side * bladeBulge, bladeLen * 0.38, 0, bladeLen);
    blade.quadraticCurveTo(-side * bladeBulge * 0.15, bladeLen * 0.5, 0, 0);
    blade.closePath();

    // Steel fill across the blade's width, dark cutting edge, spine streak.
    const steel = ctx.createLinearGradient(-side * bladeBulge, bladeLen * 0.4, side * bladeBulge, bladeLen * 0.4);
    steel.addColorStop(0, grey(0.97));
    steel.addColorStop(0.55, grey(0.72));
    steel.addColorStop(1, grey(0.88));
    ctx.fillStyle = steel;
    ctx.fill(blade);
    ctx.strokeStyle = edge;
    ctx.lineWidth = Math.max(0.6, height * 0.014);
    ctx.stroke(blade);
    const streak = new Path2D();
    streak.moveTo(0, bladeLen * 0.06);
    streak.quadraticCurveTo(side * bladeBulge * 0.45, bladeLen * 0.4, 0, bladeLen * 0.96);
    ctx.strokeStyle = grey(1, 0.8);
    ctx.lineWidth = Math.max(0.6, height * 0.012);
    ctx.stroke(streak);

    // Finger loop below the pivot: a silver ring, the metal wrapping around it.
    const cy = -(pivot.y - loopRadius - loopStroke / 2);
    const ring = ctx.createLinearGradient(0, cy + loopRadius, 0, cy - loopRadius);
    ring.addColorStop(0, grey(0.97));
    ring.addColorStop(0.55, grey(0.72));
    ring.addColorStop(1, grey(0.88));
    ctx.beginPath();
    ctx.arc(0, cy, loopRadius, 0, Math.PI * 2);
    ctx.strokeStyle = ring;
    ctx.lineWidth = loopStroke;
    ctx.stroke();
    ctx.strokeStyle = grey(0.35, 0.9 * 0.5);
    ctx.lineWidth = Math.max(0.5, height * 0.01);
    for (const r of [loopRadius + loopStroke / 2, Math.max(0, loopRadius - loopStroke / 2)]) {
      ctx.beginPath();
      ctx.arc(0, cy, r, 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.restore();
  }

  // Pivot rivet: a small radial-shaded dome.
  const r = height * 0.055;
  const rivet = ctx.createRadialGradient(pivot.x - r * 0.35, pivot.y + r * 0.35, 0, pivot.x, pivot.y, r * 1.4);
  rivet.addColorStop(0, grey(0.85));
  rivet.addColorStop(1, grey(0.3));
  ctx.beginPath();
  ctx.arc(pivot.x, pivot.y, r, 0, Math.PI * 2);
  ctx.fillStyle = rivet;
  ctx.fill();
  ctx.restore();
}
